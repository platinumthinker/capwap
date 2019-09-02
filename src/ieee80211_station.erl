%% Copyright (C) 2013-2017, Travelping GmbH <info@travelping.com>

%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU Affero General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.

%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU Affero General Public License for more details.

%% You should have received a copy of the GNU Affero General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(ieee80211_station).

-compile({parse_transform, cut}).

-behaviour(gen_statem).

%% API
-export([start_link/3, handle_ieee80211_frame/2, handle_ieee802_3_frame/3,
	 take_over/3, detach/1, delete/1, start_gtk_rekey/4]).

%% For testing
-export([frame_type/1, frame_type/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include("capwap_debug.hrl").
-include("capwap_packet.hrl").
-include("capwap_config.hrl").
-include("capwap_ac.hrl").
-include("ieee80211.hrl").
-include("ieee80211_station.hrl").
-include("eapol.hrl").

-import(ergw_aaa_session, [to_session/1, attr_get/2]).

-define(SERVER, ?MODULE).
-define(IDLE_TIMEOUT, 30 * 1000).
-define(SHUTDOWN_TIMEOUT, 1 * 1000).

-define(OPEN_SYSTEM, 0).
-define(SUCCESS, 0).
-define(REFUSED, 1).

-record(data, {
	  ac,
	  ac_monitor,
	  aaa_session,
	  data_path,
	  data_channel_address,
	  wtp_id,
	  wtp_session_id,
	  ssid,
	  mac,
	  mac_mode,
	  tunnel_mode,
	  out_action,
	  aid,
	  capabilities,

	  radio_mac,
	  response_ies,
	  wpa_config,
	  gtk,
	  igtk,

	  eapol_state,
	  eapol_retransmit,
	  eapol_timer,
	  cipher_state,

	  rekey_running,
	  rekey_pending,
	  rekey_control,

	  rekey_tref
	 }).

-record(auth_frame, {algo, seq_no, status, params}).

-define(DEBUG_OPTS,[]).

-define(GTK_KDE,  1).
-define(IGTK_KDE, 9).

%%%===================================================================
%%% API
%%%===================================================================
start_link(AC, ClientMAC, StationCfg) ->
    gen_statem:start_link(?MODULE, [AC, ClientMAC, StationCfg], [{debug, ?DEBUG_OPTS}]).

handle_ieee80211_frame(AC, <<FrameControl:2/bytes,
			      _Duration:16, DA:6/bytes, SA:6/bytes, BSS:6/bytes,
			      _SequenceControl:16/little-integer, FrameRest/binary>>) ->
    %% FragmentNumber = SequenceControl band 16#0f,
    %% SequenceNumber = SequenceControl bsr 4,

    <<SubType:4, Type:2, 0:2, Order:1, _:5, FromDS:1, ToDS:1>> = FrameControl,
    FrameType = frame_type(Type, SubType),
    Frame = strip_ht_control(Order, FrameRest),
    ieee80211_request(AC, FrameType, DA, SA, BSS, FromDS, ToDS, Frame);

handle_ieee80211_frame(_, Frame) ->
    lager:warning("unhandled IEEE802.11 Frame:~n~s", [capwap_tools:hexdump(Frame)]),
    {error, unhandled}.

handle_ieee802_3_frame(AC, RadioMAC, <<_EthDst:6/bytes, EthSrc:6/bytes, _/binary>> = Frame) ->
    with_station(AC, RadioMAC, EthSrc, gen_statem:cast(_, {'802.3', Frame}));
handle_ieee802_3_frame(_, _, _Frame) ->
    {error, unhandled}.

take_over(Pid, AC, StationCfg) ->
    gen_statem:call(Pid, {take_over, AC, StationCfg}).

detach(ClientMAC) ->
    case capwap_station_reg:lookup(ClientMAC) of
	{ok, Pid} ->
	    gen_statem:call(Pid, detach);
	_ ->
	    not_found
    end.

delete(Pid) when is_pid(Pid) ->
    gen_statem:call(Pid, delete).

start_gtk_rekey(Station, Controller, GTK, IGTK) ->
    gen_statem:cast(Station, {start_gtk_rekey, Controller, GTK, IGTK}).
%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
callback_mode() ->
    [handle_event_function].

init([AC, ClientMAC, StationCfg = #station_config{bss = RadioMAC}]) ->
    Data0 = init_from_cfg(StationCfg),

    lager:debug("Register station ~p ~p as ~w", [AC, ClientMAC, self()]),
    capwap_station_reg:register(ClientMAC),
    capwap_station_reg:register(AC, RadioMAC, ClientMAC),
    ACMonitor = erlang:monitor(process, AC),

    Data = Data0#data{ac = AC,
		      ac_monitor = ACMonitor,
		      mac = ClientMAC},
    {ok, initial_state(Data), Data}.

%%
%% Data transitions follow IEEE 802.11-2012, Section 10.3.2
%%

%%
%% Data 1
%%
handle_event(cast, Event = {'Authentication', DA, SA, BSS, 0, 0, Frame}, init_auth,
	     Data = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_AUTH got Authentication Request: ~p", [Event]),
    AuthFrame = decode_auth_frame(Frame),
    case AuthFrame of
	#auth_frame{algo   = ?OPEN_SYSTEM,
		    status = ?SUCCESS} ->
	    %% send Auth OK
	    wtp_send_80211(gen_auth_ok(DA, SA, BSS, Frame), Data),
	    {next_state, init_assoc, Data, ?IDLE_TIMEOUT};
	_ ->
	    %% send Auth Fail
	    wtp_send_80211(gen_auth_fail(DA, SA, BSS, Frame), Data),
	    {keep_state_and_data, [?IDLE_TIMEOUT]}
    end;

%%
%% Data 2
%%
handle_event(cast, Event = {'Authentication', _DA, _SA, BSS, 0, 0, _Frame}, init_assoc,
	   #data{radio_mac = BSS, mac_mode = local_mac}) ->
    lager:debug("in INIT_ASSOC Local-MAC Mode got Authentication Request: ~p", [Event]),
    {keep_state_and_data, [?IDLE_TIMEOUT]};

handle_event(cast, Event = {FrameType, _DA, _SA, BSS, 0, 0, Frame}, init_assoc,
	   Data0 = #data{radio_mac = BSS, mac_mode = MacMode})
  when MacMode == local_mac andalso
       (FrameType == 'Association Request' orelse FrameType == 'Reassociation Request') ->
    lager:debug("in INIT_ASSOC Local-MAC Mode got Association Request: ~p", [Event]),

    %% MAC blocks would go here!

    %% RFC 5416, Sect. 2.2.2:
    %%
    %%   While the MAC is terminated on the WTP, it is necessary for the AC to
    %%   be aware of mobility events within the WTPs.  Thus, the WTP MUST
    %%   forward the IEEE 802.11 Association Request frames to the AC.  The AC
    %%   MAY reply with a failed Association Response frame if it deems it
    %%   necessary, and upon receipt of a failed Association Response frame
    %%   from the AC, the WTP MUST send a Disassociation frame to the station.

    Data1 = assign_aid(Data0),
    Data2 = update_sta_from_mgmt_frame(FrameType, Frame, Data1),
    Data3 = aaa_association(Data2),
    Data = wtp_add_station(Data3),

    {next_state, connected, Data, ?IDLE_TIMEOUT};

handle_event(cast, Event = {'Authentication', _DA, _SA, BSS, 0, 0, _Frame}, init_assoc,
	   Data = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_ASSOC got Authentication Request: ~p", [Event]),
    %% fall-back to init_auth....
    {next_state, init_auth, Data, [postpone]};

handle_event(cast, Event = {'Deauthentication', _DA, _SA, BSS, 0, 0, _Frame}, init_assoc,
	     Data = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_ASSOC got Deauthentication: ~p", [Event]),
    {next_state, initial_state(Data), Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, Event = {FrameType, DA, SA, BSS, 0, 0, ReqFrame}, init_assoc,
	   #data{radio_mac = BSS,
		  response_ies = ResponseIEs0,
		  wpa_config = #wpa_config{
				  rsn = #wtp_wlan_rsn{
					   version = RSNversion,
					   management_frame_protection = MFP}}
		 } = Data0)
  when (FrameType == 'Association Request' orelse FrameType == 'Reassociation Request') ->
    lager:debug("in INIT_ASSOC got Association Request: ~p", [Event]),

    Data1 = assign_aid(Data0),
    Data2 = update_sta_from_mgmt_frame(FrameType, ReqFrame, Data1),
    Data3 = aaa_association(Data2),

    %% TODO: validate RSNE against Wlan Config
    #data{capabilities = #sta_cap{rsn = StaRSN0}} = Data3,
    StaRSN = StaRSN0#wtp_wlan_rsn{version = RSNversion},
    StaBinRSN =capwap_ac:rsn_ie(StaRSN, MFP /= false),
    ResponseIEs1 = lists:keystore(?WLAN_EID_RSN, 1, ResponseIEs0, {?WLAN_EID_RSN, StaBinRSN}),

    %% TODO: NasId and R1KH (MAC)
    R0KH = <<"scg4.tpip.net">>,
    ResponseIEs = [encode_fte(R0KH, BSS) | ResponseIEs1],

    IEs = build_ies(ResponseIEs),
    MgmtFrame = <<16#01:16/integer-little, 0:16/integer-little,
		  (Data3#data.aid):16/integer-little, IEs/binary>>,

    {Type, SubType} = frame_type('Association Response'),
    FrameControl = <<SubType:4, Type:2, 0:2, 0:6, 0:1, 0:1>>,
    Duration = 0,
    SequenceControl = 0,
    Frame = <<FrameControl/binary,
	      Duration:16/integer-little,
	      SA:6/bytes, DA:6/bytes, BSS:6/bytes,
	      SequenceControl:16,
	      MgmtFrame/binary>>,
    wtp_send_80211(Frame, Data3),

    Data = wtp_add_station(Data3),

    {next_state, connected, Data, ?IDLE_TIMEOUT};

%%
%% Data 3
%%
handle_event(cast, Event = {'Disassociation', _DA, _SA, BSS, 0, 0, _Frame}, init_start,
	   Data = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_START got Disassociation: ~p", [Event]),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, init_assoc, Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, Event = {'Deauthentication', _DA, _SA, BSS, 0, 0, _Frame}, init_start,
	     Data = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_START got Deauthentication: ~p", [Event]),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, initial_state(Data), Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, Event = {'Null', _DA, _SA, BSS, 0, 1, <<>>}, init_start,
	   Data0 = #data{radio_mac = BSS}) ->
    lager:debug("in INIT_START got Null: ~p", [Event]),
    Data = wtp_add_station(Data0),
    {next_state, connected, Data, ?IDLE_TIMEOUT};

%%
%% Data 4
%%
handle_event(timeout, _, connected, _Data) ->
    lager:warning("idle timeout in CONNECTED"),
    {keep_state_and_data, [?IDLE_TIMEOUT]};

handle_event(cast, {'802.3', Data}, connected, _Data) ->
    lager:error("in CONNECTED got 802.3 Data:~n~s", [capwap_tools:hexdump(Data)]),
    {keep_state_and_data, [?IDLE_TIMEOUT]};

handle_event(cast, Event = {FrameType, _DA, _SA, BSS, 0, 0, Frame}, connected,
	  Data0 = #data{radio_mac = BSS, mac_mode = MacMode})
  when MacMode == local_mac andalso
       (FrameType == 'Association Request' orelse FrameType == 'Reassociation Request') ->
    lager:debug("in CONNECTED Local-MAC Mode got Association Request: ~p", [Event]),

    %% Mobility Event!!! The station Reattached to the SAME AP and the AP had not yet
    %% deleted the Station

    %% MAC blocks would go here!

    %% RFC 5416, Sect. 2.2.2:
    %%
    %%   While the MAC is terminated on the WTP, it is necessary for the AC to
    %%   be aware of mobility events within the WTPs.  Thus, the WTP MUST
    %%   forward the IEEE 802.11 Association Request frames to the AC.  The AC
    %%   MAY reply with a failed Association Response frame if it deems it
    %%   necessary, and upon receipt of a failed Association Response frame
    %%   from the AC, the WTP MUST send a Disassociation frame to the station.

    Data1 = update_sta_from_mgmt_frame(FrameType, Frame, Data0),
    Data = wtp_add_station(Data1),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(cast, Event = {'Disassociation', _DA, _SA, BSS, 0, 0, _Frame}, connected,
	  Data = #data{radio_mac = BSS}) ->
    lager:debug("in CONNECTED got Disassociation: ~p", [Event]),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, init_assoc, Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, Event = {'Deauthentication', _DA, _SA, BSS, 0, 0, _Frame}, connected,
	     Data = #data{radio_mac = BSS}) ->
    lager:debug("in CONNECTED got Deauthentication: ~p", [Event]),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, initial_state(Data), Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, {'EAPOL', _DA, _SA, BSS, AuthData}, connected,
	  Data0 = #data{radio_mac = BSS, rekey_running = ptk}) ->
    Data = rsna_4way_handshake(eapol:decode(AuthData), Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(cast, {'EAPOL', _DA, _SA, BSS, AuthData}, connected,
	  Data0 = #data{radio_mac = BSS, rekey_running = gtk}) ->
    Data = rsna_2way_handshake(eapol:decode(AuthData), Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(cast, {'EAPOL', _DA, _SA, BSS, EAPData}, connected,
	  Data0 = #data{radio_mac = BSS, eapol_state = {request, _}}) ->
    Data = eap_handshake(eapol:decode(EAPData), Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(cast, {'FT', DA, SA, BSS, _Action, STA, TargetAP, ReqBody} = Event,
	     connected, Data = #data{cipher_state = #ccmp{akm_algo = AKM}})
  when AKM == 'FT-802.1x'; AKM == 'FT-PSK' ->
    lager:info("in CONNECTED got FT over-the-DS: ~p", [Event]),
    ListIE = [ {Id, Value} || <<Id:8, Len:8, Value:Len/bytes>> <= ReqBody ],
    lager:info("in CONNECTED got FT over-the-DS: ~p", [ListIE]),

    case capwap_wtp_reg:lookup(TargetAP) of
	{ok, Pid} ->
	    %%
	    %% IEEE 802.11-2012, 12.8.2 FT authentication sequence: contents of first message
	    %%
	    %% FTO→Target AP:
	    %%   FT Request (FTO address, TargetAP address, RSNE[PMKR0Name], MDE, FTE[SNonce, R0KH-ID])

	    lager:info("in CONNECTED got FT over-the-DS to: ~p", [Pid]),
	    StaCfg = capwap_ac:get_station_config(Pid, TargetAP),
	    lager:info("in CONNECTED got FT over-the-DS to: ~p", [lager:pr(StaCfg, ?MODULE)]),

	    RSNE = proplists:get_value(?WLAN_EID_RSN, ListIE),
	    <<RSNVersion:16/little, RSNData/binary>> = RSNE,
	    RSN = decode_rsne(group_cipher_suite, RSNData, #wtp_wlan_rsn{version = RSNVersion}),

	    MDomain = proplists:get_value(?WLAN_EID_MOBILITY_DOMAIN, ListIE),
	    FTE = proplists:get_value(?WLAN_EID_FAST_BSS_TRANSITION, ListIE),
	    FT = decode_fte(FTE),

	    lager:info("in CONNECTED got FT over-the-DS: ~p", [lager:pr(RSN, ?MODULE)]),
	    lager:info("in CONNECTED got FT over-the-DS: ~p", [lager:pr(FT, ?MODULE)]),

	    %%
	    %% IEEE 802.11-2012, 12.8.3 FT authentication sequence: contents of second message
	    %%
	    %% Target AP→FTO:
	    %%  FT Response (FTO address, TargetAP address, Status, RSNE[PMKR0Name], MDE, FTE[ANonce, SNonce, R1KH-ID, R0KH-ID])

	    %% Target AP Beacon RSN with PMKID List set to what the Sta requested
	    #station_config{wpa_config = #wpa_config{rsn = DestRSN}} = StaCfg,
	    lager:info("Target RSN0: ~p", [lager:pr(DestRSN, ?MODULE)]),

	    DestMDomain = MDomain,   %% TODO: Should be Target AP MDomain...

	    ANonce = crypto:strong_rand_bytes(32),
	    DestFTE = #fte{anonce = ANonce,
			   snonce = FT#fte.snonce,
			   r0kh = FT#fte.r0kh,
			   r1kh = StaCfg#station_config.bss},

	    lager:info("Target RSN: ~p", [lager:pr(DestRSN, ?MODULE)]),
	    lager:info("Target MDomain: ~p", [lager:pr(DestMDomain, ?MODULE)]),
	    lager:info("Target FTE: ~p", [lager:pr(DestFTE, ?MODULE)]),

	    %% TODO: check the MFP logic.....
	    DestRSNie = capwap_ac:rsn_ie(DestRSN, RSN#wtp_wlan_rsn.pmk_ids,
					 DestRSN#wtp_wlan_rsn.management_frame_protection),
	    lager:info("Target RSNie: ~p", [pbkdf2:to_hex(DestRSNie)]),

	    DestMDomainIE = capwap_ac:ieee_802_11_ie(?WLAN_EID_MOBILITY_DOMAIN, MDomain),
	    lager:info("Target MDomainIE: ~p", [pbkdf2:to_hex(DestMDomainIE)]),

	    DestFTie = ft_ie(DestFTE),
	    lager:info("Target FTie: ~p", [pbkdf2:to_hex(DestFTie)]),

	    Action = 2,    %% Response
	    Status = 0,
	    RespBody = <<DestRSNie/binary, DestMDomainIE/binary, DestFTie/binary>>,
	    ActionFrame = <<?WLAN_ACTION_FT, Action:8, STA:6/bytes, TargetAP:6/bytes,
			    Status:16/little, RespBody/binary>>,

	    {Type, SubType} = frame_type('Action'),
	    FrameControl = <<SubType:4, Type:2, 0:2, 0:6, 0:1, 0:1>>,
	    Duration = 0,
	    SequenceControl = 0,
	    Frame = <<FrameControl/binary,
		      Duration:16/integer-little,
		      SA:6/bytes, DA:6/bytes, BSS:6/bytes,
		      SequenceControl:16,
		      ActionFrame/binary>>,
	    wtp_send_80211(Frame, Data),

	    ok;
	_ ->
	    lager:error("in CONNECTED got FT over-the-DS external Target AP")
    end,
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(info, {rekey, Type}, connected, Data0) ->
    lager:warning("in CONNECTED got REKEY: ~p", [Type]),
    Data = rekey_start(Type, Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(info, Event = {eapol_retransmit, {packet, EAPData}}, connected,
	  Data0 = #data{eapol_retransmit = TxCnt})
  when TxCnt < 4 ->
    lager:warning("in CONNECTED got EAPOL retransmit: ~p", [Event]),
    Data = send_eapol_packet(EAPData, Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(info, Event = {eapol_retransmit, {key, Flags, KeyData}}, connected,
	  Data0 = #data{eapol_retransmit = TxCnt})
  when TxCnt < 4 ->
    lager:warning("in CONNECTED got EAPOL retransmit: ~p", [Event]),
    Data = send_eapol_key(Flags, KeyData, Data0),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(info, Event = {eapol_retransmit, _Msg}, connected, Data) ->
    lager:warning("in CONNECTED got EAPOL retransmit final TIMEOUT: ~p", [Event]),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, initial_state(Data), Data, ?SHUTDOWN_TIMEOUT};

handle_event(cast, {start_gtk_rekey, RekeyCtl, GTKnew, IGTKnew}, connected,
	  #data{gtk = GTK, igtk = IGTK} = Data)
  when GTKnew#ieee80211_key.index == GTK#ieee80211_key.index andalso
       IGTKnew#ieee80211_key.index == IGTK#ieee80211_key.index ->
    capwap_ac_gtk_rekey:gtk_rekey_done(RekeyCtl, self()),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event(cast, Event = {start_gtk_rekey, RekeyCtl, GTKnew, IGTKnew}, connected,
	  #data{gtk = GTK, igtk = IGTK} = Data0)
  when GTKnew#ieee80211_key.index /= GTK#ieee80211_key.index orelse
       IGTKnew#ieee80211_key.index /= IGTK#ieee80211_key.index ->
    lager:debug("in CONNECTED got Group rekey: ~p", [Event]),
    Data = rekey_start(gtk, Data0#data{gtk = GTKnew, igtk = IGTKnew, rekey_control = RekeyCtl}),
    {keep_state, Data, [?IDLE_TIMEOUT]};

handle_event({call, From}, {take_over, AC, StationCfg =
				#station_config{
				   bss = RadioMAC}} = Event,
	     State, #data{ac = OldAC, ac_monitor = OldACMonitor,
			  data_path = _OldDataPath,
			  radio_mac = OldRadioMAC, mac = ClientMAC} = Data0) ->
    lager:debug("in ~p got TAKE-OVER: ~p", [State, Event]),
    lager:debug("Takeover station ~p as ~w", [{OldAC, OldRadioMAC, ClientMAC}, self()]),
    lager:debug("Register station ~p as ~w", [{AC, RadioMAC, ClientMAC}, self()]),

    if State =:= connected ->
	    aaa_disassociation(Data0);
       true ->
	    ok
    end,

    wtp_del_station(Data0),
    capwap_ac:station_detaching(OldAC),
    capwap_station_reg:unregister(OldAC, OldRadioMAC, ClientMAC),
    erlang:demonitor(OldACMonitor, [flush]),

    capwap_station_reg:register(AC, RadioMAC, ClientMAC),
    ACMonitor = erlang:monitor(process, AC),

    Data = update_from_cfg(StationCfg, Data0#data{ac = AC, ac_monitor = ACMonitor}),
    {next_state, initial_state(Data), Data, [{reply, From, {ok, self()}}, ?IDLE_TIMEOUT]};

handle_event({call, From}, delete, connected, Data) ->
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, initial_state(Data), Data, [{reply, From, ok}, ?SHUTDOWN_TIMEOUT]};

handle_event({call, From}, Event, connected, Data)
  when Event == detach; Event == delete ->
    wtp_del_station(Data),
    aaa_disassociation(Data),
    {next_state, initial_state(Data), Data, [{reply, From, ok}, ?SHUTDOWN_TIMEOUT]};

handle_event({call, From}, Event, _State, _Data) when Event == detach; Event == delete ->
    {keep_state_and_data, [{reply, From, {error, not_attached}}, ?IDLE_TIMEOUT]};

handle_event(timeout, _, State, _Data) ->
    lager:warning("idle timeout in ~p", [State]),
    {stop, normal};

handle_event(info, {'DOWN', _ACMonitor, process, AC, _Info}, _State, #data{ac = AC}) ->
    lager:warning("AC died ~w", [AC]),
    {stop, normal};

handle_event({call, From}, get_aaa_session, _State, #data{aaa_session = AAA}) ->
    {keep_state_and_data, [{reply, From, {ok, AAA}}, ?IDLE_TIMEOUT]};

handle_event(Type, Event, State, _Data) ->
    lager:warning("in ~p got unexpexted: ~p:~p", [State, Type, Event]),
    {keep_state_and_data, [?IDLE_TIMEOUT]}.

terminate(_Reason, State, Data = #data{ac = AC, mac = MAC}) ->
    if State == connected ->
	    wtp_del_station(Data),
	    aaa_disassociation(Data);
       true ->
	    ok
    end,
    capwap_ac:station_detaching(AC),
    lager:warning("Station ~s terminated in State ~w", [capwap_tools:format_eui(MAC), State]),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_from_cfg(StationCfg) ->
    update_from_cfg(StationCfg,
		    #data{capabilities = #sta_cap{},
			  rekey_running = false,
			  rekey_pending = []}).

convert_ies_from_bss(IEs) ->
    lists:foldl(fun({IE = <<Id:8, _/binary>>, Flags}, Acc) ->
			case proplists:get_bool(probe_response, Flags) of
			    true -> [{Id, IE} | Acc];
			    _    -> Acc
			end
		end, [], IEs).

build_ies(IEs) ->
    << <<IE/binary>> || {_Id, IE} <- lists:keysort(1, IEs) >>.

update_from_cfg(#station_config{data_path = DataPath,
				wtp_data_channel_address = WTPDataChannelAddress,
				wtp_id = WtpId,
				wtp_session_id = SessionId,
				mac_mode = MacMode,
				tunnel_mode = TunnelMode,
				bss = BSS,
				bss_ies = IEs,
				wpa_config = WpaConfig,
				gtk = GTK,
				igtk = IGTK
			       }, Data) ->
    Data#data{data_path = DataPath,
		data_channel_address = WTPDataChannelAddress,
		wtp_id = WtpId,
		wtp_session_id = SessionId,
		mac_mode = MacMode,
		tunnel_mode = TunnelMode,
		radio_mac = BSS,
		response_ies = convert_ies_from_bss(IEs),
		wpa_config = WpaConfig,
		gtk = GTK,
		igtk = IGTK
	       }.

with_station(AC, BSS, StationMAC, Fun) ->
    lager:debug("search Station ~p", [{AC, StationMAC}]),
    case capwap_station_reg:lookup(AC, BSS, StationMAC) of
	not_found ->
	    lager:debug("Station not found"),
	    {error, not_found};

	{ok, Station} ->
	    lager:debug("found Station as ~p", [Station]),
	    Fun(Station)
    end.

gen_auth_ok(DA, SA, BSS, _InFrame) ->
    Frame = encode_auth_frame(#auth_frame{algo   = ?OPEN_SYSTEM, seq_no = 2,
					  status = ?SUCCESS, params = <<>>}),

    {Type, SubType} = frame_type('Authentication'),
    FrameControl = <<SubType:4, Type:2, 0:2, 0:6, 0:1, 0:1>>,
    Duration = 0,
    SequenceControl = 0,
    <<FrameControl/binary,
      Duration:16/integer-little,
      SA:6/bytes, DA:6/bytes, BSS:6/bytes,
      SequenceControl:16,
      Frame/binary>>.

gen_auth_fail(DA, SA, BSS, _InFrame) ->
    Frame = encode_auth_frame(#auth_frame{algo   = ?OPEN_SYSTEM, seq_no = 2,
					  status = ?REFUSED, params = <<>>}),

    {Type, SubType} = frame_type('Authentication'),
    FrameControl = <<SubType:4, Type:2, 0:2, 0:6, 0:1, 0:1>>,
    Duration = 0,
    SequenceControl = 0,
    <<FrameControl/binary,
      Duration:16/integer-little,
      SA:6/bytes, DA:6/bytes, BSS:6/bytes,
      SequenceControl:16,
      Frame/binary>>.

station_from_mgmt_frame(DA, SA, BSS) ->
    case BSS of
	DA -> SA;
	SA -> DA;
	_  -> undefined
    end.

ieee80211_request(AC, FrameType, DA, SA, BSS, FromDS, ToDS, Frame)
  when FrameType == 'Deauthentication';
       FrameType == 'Disassociation' ->
    lager:warning("got IEEE 802.11 Frame: ~p", [{FrameType, DA, SA, BSS, FromDS, ToDS, Frame}]),

    STA = station_from_mgmt_frame(DA, SA, BSS),
    with_station(AC, BSS, STA, gen_statem:cast(_, {FrameType, DA, SA, BSS, FromDS, ToDS, Frame}));

ieee80211_request(_AC, _FrameType, _DA, SA, BSS, _FromDS, _ToDS, _Frame)
  when SA == BSS ->
    %% OpenCAPWAP is stupid, it mirrors our own Frame back to us....
    ok;

ieee80211_request(AC, FrameType, DA, SA, BSS, FromDS, ToDS, Frame)
  when FrameType == 'Authentication';
       FrameType == 'Association Request';
       FrameType == 'Reassociation Request';
       FrameType == 'Null' ->
    lager:debug("search Station ~p", [{AC, SA}]),
    Found = case capwap_station_reg:lookup(AC, BSS, SA) of
		not_found ->
		    lager:debug("not found"),
		    capwap_ac:new_station(AC, BSS, SA);
		Ok = {ok, Station0} ->
		    lager:debug("found as ~p", [Station0]),
		    Ok
	    end,
    case Found of
	{ok, Station} ->
	    gen_statem:cast(Station, {FrameType, DA, SA, BSS, FromDS, ToDS, Frame});
	Other ->
	    Other
    end;

ieee80211_request(_AC, FrameType, _DA, _SA, _BSS, _FromDS, _ToDS, _Frame)
  when FrameType == 'Probe Request' ->
    ok;

ieee80211_request(AC, 'QoS Data', DA, SA, BSS, _FromDS = 0, _ToDS = 1,
		  _Frame = <<_QoS:16, ?LLC_DSAP_SNAP, ?LLC_SSAP_SNAP,
			    ?LLC_CNTL_SNAP, ?SNAP_ORG_ETHERNET,
			    ?ETH_P_PAE:16, AuthData/binary>>) ->
    with_station(AC, BSS, SA, gen_statem:cast(_, {'EAPOL', DA, SA, BSS, AuthData})),
    ok;
ieee80211_request(AC, 'Data', DA, SA, BSS, _FromDS = 0, _ToDS = 1,
		  _Frame = <<?LLC_DSAP_SNAP, ?LLC_SSAP_SNAP,
			    ?LLC_CNTL_SNAP, ?SNAP_ORG_ETHERNET,
			    ?ETH_P_PAE:16, AuthData/binary>>) ->
    with_station(AC, BSS, SA, gen_statem:cast(_, {'EAPOL', DA, SA, BSS, AuthData})),
    ok;
ieee80211_request(AC, 'Action', DA, SA, BSS, _FromDS = 0, _ToDS = 0,
		  _Frame = <<?WLAN_ACTION_FT, Action:8, STA:6/bytes, TargetAP:6/bytes, Body/binary>>) ->
    with_station(AC, BSS, SA, gen_statem:cast(_, {'FT', DA, SA, BSS, Action, STA, TargetAP, Body})),
    ok;
ieee80211_request(_AC, FrameType, DA, SA, BSS, FromDS, ToDS, Frame) ->
    lager:warning("unhandled IEEE 802.11 Frame: ~p", [{FrameType, DA, SA, BSS, FromDS, ToDS, Frame}]),
    {error, unhandled}.

%% partially en/decode Authentication Frames
decode_auth_frame(<<Algo:16/little-integer, SeqNo:16/little-integer,
		    Status:16/little-integer, Params/binary>>) ->
    #auth_frame{algo   = Algo,
		seq_no = SeqNo,
		status = Status,
		params = Params};
decode_auth_frame(_) ->
    invalid.

encode_auth_frame(#auth_frame{algo   = Algo, seq_no = SeqNo,
			      status = Status, params = Params}) ->
    <<Algo:16/little-integer, SeqNo:16/little-integer,
      Status:16/little-integer, Params/binary>>.

assign_aid(Data) ->
    %% FIXME: generate uniq value...
    Data#data{aid = (rand:uniform(2007) + 1) bor 16#C000}.

update_sta_from_mgmt_frame(FrameType, Frame, Data)
  when (FrameType == 'Association Request') ->
    <<_Capability:16, _ListenInterval:16,
      IEs/binary>> = Frame,
    update_sta_from_mgmt_frame_ies(IEs, Data);
update_sta_from_mgmt_frame(FrameType, Frame, Data)
  when (FrameType == 'Reassociation Request') ->
    <<_Capability:16, _ListenInterval:16,
      _CurrentAP:6/bytes, IEs/binary>> = Frame,
    update_sta_from_mgmt_frame_ies(IEs, Data);
update_sta_from_mgmt_frame(_FrameType, _Frame, Data) ->
    Data.

update_sta_from_mgmt_frame_ies(IEs, #data{aid = AID, capabilities = Cap0} = Data0) ->
    Data1 = Data0#data{capabilities = Cap0#sta_cap{aid = AID}},
    ListIE = [ {Id, Data} || <<Id:8, Len:8, Data:Len/bytes>> <= IEs ],
    Data = lists:foldl(fun update_sta_from_mgmt_frame_ie/2, Data1, ListIE),

    lager:debug("New Station Caps: ~p", [lager:pr(Data#data.capabilities, ?MODULE)]),
    case Data#data.capabilities of
	#sta_cap{rsn = #wtp_wlan_rsn{} = RSN} ->
	    lager:info("STA: ~p, Ciphers: Group ~p, PairWise: ~p, AKM: ~p, Caps: ~w, Mgmt: ~p",
		       [capwap_tools:format_eui(Data#data.mac),
			RSN#wtp_wlan_rsn.group_cipher_suite, RSN#wtp_wlan_rsn.cipher_suites,
			RSN#wtp_wlan_rsn.akm_suites, RSN#wtp_wlan_rsn.capabilities,
			RSN#wtp_wlan_rsn.group_mgmt_cipher_suite]);
	_ -> nothing
    end,
    Data.

smps2atom(0) -> static;
smps2atom(1) -> dynamic;
smps2atom(2) -> reserved;
smps2atom(3) -> disabled.

update_sta_from_mgmt_frame_ie(IE = {?WLAN_EID_HT_CAP, HtCap},
				  #data{capabilities = Cap} = Data) ->
    lager:debug("Mgmt IE HT CAP: ~p", [IE]),
    <<CapInfo:2/bytes, AMPDU_ParamsInfo:8/bits, MCSinfo:16/bytes,
      ExtHtCapInfo:2/bytes, TxBFinfo:4/bytes, ASelCap:8/bits>> = HtCap,
    lager:debug("CapInfo: ~p, AMPDU: ~p, MCS: ~p, ExtHt: ~p, TXBf: ~p, ASEL: ~p",
		[CapInfo, AMPDU_ParamsInfo, MCSinfo, ExtHtCapInfo, TxBFinfo, ASelCap]),
    <<_TxSTBC:1, SGI40Mhz:1, SGI20Mhz:1, _GFPreamble:1, SMPS:2, _Only20Mhz:1, _LDPC:1,
      _TXOP:1, _FortyMHzIntol:1, _PSMPSup:1, _DSSSMode:1, _MaxAMSDULen:1, BAckDelay:1, _RxSTBC:2>>
	= CapInfo,
    <<_:3, AMPDU_Density:3, AMPDU_Factor:2>> = AMPDU_ParamsInfo,
    <<RxMask:10/bytes, RxHighest:16/integer-little, _TxParms:8, _:3/bytes>> = MCSinfo,

    Data#data{
      capabilities =
	  Cap#sta_cap{sgi_20mhz = (SGI20Mhz == 1), sgi_40mhz = (SGI40Mhz == 1),
		      smps = smps2atom(SMPS), back_delay = (BAckDelay == 1),
		      ampdu_density = AMPDU_Density, ampdu_factor = AMPDU_Factor,
		      rx_mask = RxMask, rx_highest = RxHighest
		     }};

%% Vendor Specific:
%%  OUI:  00-50-F2 - Microsoft
%%  Type: 2        - WMM/WME
%%  WME Subtype: 0 - IE
%%  WME Version: 1
update_sta_from_mgmt_frame_ie(IE = {?WLAN_EID_VENDOR_SPECIFIC,
				    <<16#00, 16#50, 16#F2, 2, 0, 1, _/binary>>},
				  #data{capabilities = Cap} = Data) ->
    lager:debug("Mgmt IE WMM: ~p", [IE]),
    Data#data{
      capabilities =
	  Cap#sta_cap{wmm = true}};

update_sta_from_mgmt_frame_ie(IE = {?WLAN_EID_RSN, <<RSNVersion:16/little, RSNData/binary>> = RSNE},
			      #data{capabilities = Cap} = Data) ->
    lager:debug("Mgmt IE RSN: ~p", [IE]),
    RSN = decode_rsne(group_cipher_suite, RSNData, #wtp_wlan_rsn{version = RSNVersion}),
    Data#data{
      capabilities =
	  Cap#sta_cap{last_rsne = RSNE, rsn = RSN}};

update_sta_from_mgmt_frame_ie(_IE = {?WLAN_EID_SSID, SSID},
			      #data{} = Data) ->
    Data#data{ssid = SSID };


update_sta_from_mgmt_frame_ie(IE = {_Id, _Value}, Data) ->
    lager:debug("Mgmt IE: ~p", [IE]),
    Data.

decode_rsne(_, <<>>, RSN) ->
    RSN;
decode_rsne(group_cipher_suite, <<GroupCipherSuite:4/bytes, Next/binary>>, RSN) ->
    decode_rsne(pairwise_cipher_suite, Next, RSN#wtp_wlan_rsn{group_cipher_suite = GroupCipherSuite});
decode_rsne(pairwise_cipher_suite, <<Count:16/little, Data/binary>>, RSN) ->
    Length = Count * 4,
    <<Suites:Length/bytes, Next/binary>> = Data,
    decode_rsne(auth_key_management, Next,
		RSN#wtp_wlan_rsn{cipher_suites = [ Id || <<Id:4/bytes>> <= Suites ]});
decode_rsne(auth_key_management, <<Count:16/little, Data/binary>>, RSN) ->
    Length = Count * 4,
    <<Suites:Length/bytes, Next/binary>> = Data,
    decode_rsne(rsn_capabilities, Next,
		RSN#wtp_wlan_rsn{akm_suites =
				     [ capwap_packet:decode_akm_suite(Id) || <<Id:32>> <= Suites ]});
decode_rsne(rsn_capabilities, <<RSNCaps:16/little, Next/binary>>, RSN) ->
    decode_rsne(pmkid, Next, RSN#wtp_wlan_rsn{capabilities = RSNCaps});
decode_rsne(pmkid, <<0:16/little, Next/binary>>, RSN) ->
    decode_rsne(group_management_cipher, Next, RSN);
decode_rsne(pmkid, <<Count:16/little, Data/binary>>, RSN) ->
    Length = Count * 16,
    <<PMKIds:Length/bytes, Next/binary>> = Data,
    decode_rsne(group_management_cipher, Next, RSN#wtp_wlan_rsn{pmk_ids = [ Id || <<Id:16/bytes>> <= PMKIds ]});
decode_rsne(group_management_cipher, <<GroupMgmtCipherSuite:32>>, RSN)
  when (RSN#wtp_wlan_rsn.capabilities band 16#0080) /= 0 ->
    RSN#wtp_wlan_rsn{group_mgmt_cipher_suite = capwap_packet:decode_cipher_suite(GroupMgmtCipherSuite)};
decode_rsne(group_management_cipher, <<GroupMgmtCipherSuite:32>>, RSN) ->
    lager:error("STA send a GroupMgmtCipher but DID NOT indicate MFP capabilities: ~p, ~4.16.0b",
		[capwap_packet:decode_cipher_suite(GroupMgmtCipherSuite), RSN#wtp_wlan_rsn.capabilities]),
    RSN.

ft_ie_mic(#fte{mic = undefined}) ->
    {0, <<0:(16*8)>>}.

ft_ie_nonce(Nonce)
  when is_binary(Nonce),
       byte_size(Nonce) == 32 ->
    Nonce;
ft_ie_nonce(_Nonce) ->
    <<0:(32*8)>>.

ft_ie_opt(Id, Opt) when is_binary(Opt) ->
    [Id, size(Opt), Opt];
ft_ie_opt(_Id, _Opt) ->
    [].

ft_ie(#fte{anonce = ANonce, snonce = SNonce,
	   r0kh = R0KH, r1kh = R1KH,
	   gtk = GTK, igtk = IGTK} = FTE) ->
    {Count, MIC} = ft_ie_mic(FTE),
    IE = [0, Count, MIC, ft_ie_nonce(ANonce), ft_ie_nonce(SNonce),
	  [ft_ie_opt(I, O) || {I, O} <- [{1, R1KH}, {2, GTK}, {3, R0KH}, {4, IGTK}]]],
    capwap_ac:ieee_802_11_ie(?WLAN_EID_FAST_BSS_TRANSITION, iolist_to_binary(IE)).

ft_ie(R0KH, R1KH) ->
%% Page 1312
%% The (Re)Association Response frame from the AP shall contain an MDE, with contents as presented in
%% Beacon and Probe Response frames. The FTE shall include the key holder identities of the AP, the R0KH-ID
%% and R1KH-ID, set to the values of dot11FTR0KeyHolderID and dot11FTR1KeyHolderID, respectively. The
%% FTE shall have a MIC element count of zero (i.e., no MIC present) and have ANonce, SNonce, and MIC
%% fields set to 0.
    R1KHie = <<1:8, (size(R1KH)):8, R1KH/binary>>,
    R0KHie = <<3:8, (size(R0KH)):8, R0KH/binary>>,
    capwap_ac:ieee_802_11_ie(?WLAN_EID_FAST_BSS_TRANSITION, <<0:8, 0:8, 0:(16 * 8), 0:(32 * 8), 0:(32 * 8),
							      R1KHie/binary, R0KHie/binary>>).
encode_fte(R0KH, R1KH) ->
    {?WLAN_EID_FAST_BSS_TRANSITION, ft_ie(R0KH, R1KH)}.

decode_fte(<<_:8, _Count:8, MIC:16/bytes, ANonce:32/bytes, SNonce:32/bytes, Opt/binary>>) ->
    FT = #fte{mic = MIC,
	      anonce = ANonce,
	      snonce = SNonce},
    OptList = [ {Id, Data} || <<Id:8, Len:8, Data:Len/bytes>> <= Opt ],
    lists:foldl(fun decode_fte_opt/2, FT, OptList).

decode_fte_opt({1, R1KH}, FT) ->
    FT#fte{r1kh = R1KH};
decode_fte_opt({2, GTK}, FT) ->
    FT#fte{gtk = GTK};
decode_fte_opt({3, R0KH}, FT) ->
    FT#fte{r0kh = R0KH};
decode_fte_opt({4, IGTK}, FT) ->
    FT#fte{igtk = IGTK};
decode_fte_opt(_, FT) ->
    FT.

%% ti_ie(Type, Interval) ->
%%     capwap_ac:ieee_802_11_ie(?WLAN_EID_TIMEOUT_INTERVAL, <<Type:8, Interval:32/little>>).

strip_ht_control(0, Frame) ->
    Frame;
strip_ht_control(1, <<_HT:4/bytes, Frame/binary>>) ->
    Frame.

%% Accounting Support
ip2str(IP) ->
    iolist_to_binary(inet_parse:ntoa(IP)).

tunnel_medium({_,_,_,_}) ->
    'IPv4';
tunnel_medium({_,_,_,_,_,_,_,_}) ->
    'IPv6'.

add_tunnel_info({Address, _Port}, SessionData) ->
    [{'Tunnel-Type', 'CAPWAP'},
     {'Tunnel-Medium-Type', tunnel_medium(Address)},
     {'Tunnel-Client-Endpoint', ip2str(Address)}
     |SessionData].

wtp_add_station(#data{ac = AC, radio_mac = BSS, mac = MAC, capabilities = Caps,
		       wpa_config = #wpa_config{privacy = Privacy},
		       cipher_state = CipherData} = Data) ->
    if Privacy ->
	    capwap_ac:add_station(AC, BSS, MAC, Caps, {true, false, CipherData}),
	    init_eapol(Data);
       true ->
	    capwap_ac:add_station(AC, BSS, MAC, Caps, {false, false, undefined}),
	    Data
    end.

wtp_del_station(#data{ac = AC, radio_mac = BSS, mac = MAC}) ->
    capwap_ac:del_station(AC, BSS, MAC).

wtp_send_80211(Data,  #data{ac = AC, radio_mac = BSS}) when is_binary(Data) ->
    capwap_ac:send_80211(AC, BSS, Data).

accounting_update(STA, SessionOpts) ->
    lager:debug("accounting_update: ~p, ~p", [STA, attr_get('MAC', SessionOpts)]),
    case attr_get('MAC', SessionOpts) of
	{ok, MAC} ->
	    STAStats = capwap_dp:get_station(MAC),
	    lager:debug("STA Stats: ~p", [STAStats]),
	    {_MAC, _VLan, _RadioId, _BSS, {RcvdPkts, SendPkts, RcvdBytes, SendBytes, _RSSI, _SNR, _DR}} = STAStats,
	    Acc = [{'InPackets',  RcvdPkts},
		    {'OutPackets', SendPkts},
		    {'InOctets',   RcvdBytes},
		    {'OutOctets',  SendBytes}],
	    ergw_aaa_session:merge(SessionOpts, to_session(Acc));
	_ ->
	    SessionOpts
    end.

aaa_association(Data = #data{mac = MAC, data_channel_address = WTPDataChannelAddress,
				wtp_id = WtpId, wtp_session_id = WtpSessionId,
				radio_mac = BSSID, ssid = SSID}) ->
    MACStr = capwap_tools:format_eui(MAC),
    BSSIDStr = capwap_tools:format_eui(BSSID),
    SessionData0 = [{'Accouting-Update-Fun', fun accounting_update/2},
		    {'AAA-Application-Id', capwap_station},
		    {'Service-Type', 'TP-CAPWAP-STA'},
		    {'Framed-Protocol', 'TP-CAPWAP'},
		    {'MAC', MAC},
		    {'Username', MACStr},
		    {'Calling-Station-Id', MACStr},
		    {'Location-Id', WtpId},
		    {'BSSID', BSSIDStr},
		    {'SSID', SSID},
		    {'CAPWAP-Session-Id', <<WtpSessionId:128>>}],
    SessionData1 = add_tunnel_info(WTPDataChannelAddress, SessionData0),
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session(SessionData1)),
    lager:info("NEW session for ~w at ~p", [MAC, Session]),
    ergw_aaa_session:start(Session, to_session([])),
    Data#data{aaa_session = Session}.

aaa_disassociation(#data{aaa_session = Session}) ->
    ergw_aaa_session:stop(Session, to_session([])),
    ok.

%% Management
frame_type(2#00, 2#0000) -> 'Association Request';
frame_type(2#00, 2#0001) -> 'Association Response';
frame_type(2#00, 2#0010) -> 'Reassociation Request';
frame_type(2#00, 2#0011) -> 'Reassociation Response';
frame_type(2#00, 2#0100) -> 'Probe Request';
frame_type(2#00, 2#0101) -> 'Probe Response';
frame_type(2#00, 2#0110) -> 'Timing Advertisement';
frame_type(2#00, 2#0111) -> 'Reserved';
frame_type(2#00, 2#1000) -> 'Beacon';
frame_type(2#00, 2#1001) -> 'ATIM';
frame_type(2#00, 2#1010) -> 'Disassociation';
frame_type(2#00, 2#1011) -> 'Authentication';
frame_type(2#00, 2#1100) -> 'Deauthentication';
frame_type(2#00, 2#1101) -> 'Action';
frame_type(2#00, 2#1110) -> 'Action No Ack';
frame_type(2#00, 2#1111) -> 'Reserved';

%% Controll
frame_type(2#01, 2#0111) -> 'Control Wrapper';
frame_type(2#01, 2#1000) -> 'Block Ack Request';
frame_type(2#01, 2#1001) -> 'Block Ack';
frame_type(2#01, 2#1010) -> 'PS-Poll';
frame_type(2#01, 2#1011) -> 'RTS';
frame_type(2#01, 2#1100) -> 'CTS';
frame_type(2#01, 2#1101) -> 'ACK';
frame_type(2#01, 2#1110) -> 'CF-End';
frame_type(2#01, 2#1111) -> 'CF-End + CF-Ack';

%% Data
frame_type(2#10, 2#0000) -> 'Data';
frame_type(2#10, 2#0001) -> 'Data + CF-Ack';
frame_type(2#10, 2#0010) -> 'Data + CF-Poll';
frame_type(2#10, 2#0011) -> 'Data + CF-Ack + CF-Poll';
frame_type(2#10, 2#0100) -> 'Null';
frame_type(2#10, 2#0101) -> 'CF-Ack';
frame_type(2#10, 2#0110) -> 'CF-Poll';
frame_type(2#10, 2#0111) -> 'CF-Ack + CF-Poll';
frame_type(2#10, 2#1000) -> 'QoS Data';
frame_type(2#10, 2#1001) -> 'QoS Data + CF-Ack';
frame_type(2#10, 2#1010) -> 'QoS Data + CF-Poll';
frame_type(2#10, 2#1011) -> 'QoS Data + CF-Ack + CF-Poll';
frame_type(2#10, 2#1100) -> 'QoS Null';
frame_type(2#10, 2#1101) -> 'Reserved';
frame_type(2#10, 2#1110) -> 'QoS CF-Poll';
frame_type(2#10, 2#1111) -> 'QoS CF-Ack + CF-Poll';

frame_type(_,_)           -> 'Reserved'.

%% Management
frame_type('Association Request')         -> {2#00, 2#0000};
frame_type('Association Response')        -> {2#00, 2#0001};
frame_type('Reassociation Request')       -> {2#00, 2#0010};
frame_type('Reassociation Response')      -> {2#00, 2#0011};
frame_type('Probe Request')               -> {2#00, 2#0100};
frame_type('Probe Response')              -> {2#00, 2#0101};
frame_type('Timing Advertisement')        -> {2#00, 2#0110};
frame_type('Beacon')                      -> {2#00, 2#1000};
frame_type('ATIM')                        -> {2#00, 2#1001};
frame_type('Disassociation')              -> {2#00, 2#1010};
frame_type('Authentication')              -> {2#00, 2#1011};
frame_type('Deauthentication')            -> {2#00, 2#1100};
frame_type('Action')                      -> {2#00, 2#1101};
frame_type('Action No Ack')               -> {2#00, 2#1110};

%% Controll
frame_type('Control Wrapper')             -> {2#01, 2#0111};
frame_type('Block Ack Request')           -> {2#01, 2#1000};
frame_type('Block Ack')                   -> {2#01, 2#1001};
frame_type('PS-Poll')                     -> {2#01, 2#1010};
frame_type('RTS')                         -> {2#01, 2#1011};
frame_type('CTS')                         -> {2#01, 2#1100};
frame_type('ACK')                         -> {2#01, 2#1101};
frame_type('CF-End')                      -> {2#01, 2#1110};
frame_type('CF-End + CF-Ack')             -> {2#01, 2#1111};

%% Data
frame_type('Data')                        -> {2#10, 2#0000};
frame_type('Data + CF-Ack')               -> {2#10, 2#0001};
frame_type('Data + CF-Poll')              -> {2#10, 2#0010};
frame_type('Data + CF-Ack + CF-Poll')     -> {2#10, 2#0011};
frame_type('Null')                        -> {2#10, 2#0100};
frame_type('CF-Ack')                      -> {2#10, 2#0101};
frame_type('CF-Poll')                     -> {2#10, 2#0110};
frame_type('CF-Ack + CF-Poll')            -> {2#10, 2#0111};
frame_type('QoS Data')                    -> {2#10, 2#1000};
frame_type('QoS Data + CF-Ack')           -> {2#10, 2#1001};
frame_type('QoS Data + CF-Poll')          -> {2#10, 2#1010};
frame_type('QoS Data + CF-Ack + CF-Poll') -> {2#10, 2#1011};
frame_type('QoS Null')                    -> {2#10, 2#1100};
frame_type('Reserved')                    -> {2#10, 2#1101};
frame_type('QoS CF-Poll')                 -> {2#10, 2#1110};
frame_type('QoS CF-Ack + CF-Poll')        -> {2#10, 2#1111};

frame_type(_) ->
    {0, 0}.

pad_length(Width, Length) ->
    (Width - Length rem Width) rem Width.

%%
%% pad binary to specific length
%%   -> http://www.erlang.org/pipermail/erlang-questions/2008-December/040709.html
%%
pad_to(Width, Binary) ->
    case pad_length(Width, size(Binary)) of
	0 -> Binary;
	N -> <<Binary/binary, 0:(N*8)>>
    end.

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
	false ->
	    receive {timeout, Ref, _} -> 0
	    after 0 -> false
	    end;
	RemainingTime ->
	    RemainingTime
    end.

initial_state(#data{mac_mode = local_mac}) ->
    init_assoc;
initial_state(#data{mac_mode = split_mac}) ->
    init_auth.

stop_eapol_timer(#data{eapol_timer = TRef} = Data)
  when is_reference(TRef) ->
    cancel_timer(TRef),
    Data#data{eapol_timer = undefined};
stop_eapol_timer(Data) ->
    Data.

start_eapol_timer(Msg, Data0) ->
    Interval = 500,
    Data = stop_eapol_timer(Data0),
    lager:debug("Starting EAPOL Timer ~w ms", [Interval]),
    TRef = erlang:send_after(Interval, self(), {eapol_retransmit, Msg}),
    Data#data{eapol_timer = TRef}.

send_eapol(EAPData, Data = #data{mac = StationMAC, radio_mac = BSS}) ->
    Frame = eapol:encode_802_11(StationMAC, BSS, EAPData),
    wtp_send_80211(Frame, Data).

send_eapol_packet(EAPData, Data = #data{eapol_retransmit = TxCnt}) ->
    send_eapol(eapol:packet(EAPData), Data),
    start_eapol_timer({packet, EAPData}, Data#data{eapol_retransmit = TxCnt + 1}).

send_eapol_key(Flags, KeyData,
	       Data = #data{eapol_retransmit = TxCnt,
			    cipher_state =
				#ccmp{replay_counter = ReplayCounter} = CipherData0
			   }) ->
    CipherData = CipherData0#ccmp{replay_counter = ReplayCounter + 1},
    KeyFrame = eapol:key(Flags, KeyData, CipherData),
    send_eapol(KeyFrame, Data),
    start_eapol_timer({key, Flags, KeyData},
		      Data#data{eapol_retransmit = TxCnt + 1,
				cipher_state = CipherData}).

init_eapol(#data{capabilities = #sta_cap{rsn = #wtp_wlan_rsn{akm_suites = [AKM]}},
		  wpa_config = #wpa_config{ssid = SSID, secret = Secret}} = Data)
  when AKM == 'PSK'; AKM == 'FT-PSK' ->
    {ok, PSK} = eapol:phrase2psk(Secret, SSID),
    lager:debug("PSK: ~s", [pbkdf2:to_hex(PSK)]),
    rsna_4way_handshake({init, PSK}, Data#data{rekey_running = ptk});

init_eapol(#data{capabilities = #sta_cap{rsn = #wtp_wlan_rsn{akm_suites = [AKM]}},
		  wpa_config = #wpa_config{ssid = SSID}} = Data)
  when AKM == '802.1x'; AKM == 'FT-802.1x' ->
    ReqData = <<0, "networkid=", SSID/binary, ",nasid=SCG4,portid=1">>,
    Id = 1,
    EAPData = eapol:request(Id, identity, ReqData),
    send_eapol_packet(EAPData, Data#data{rekey_running = 'WPA',
					 eapol_state = {request, Id},
					 eapol_retransmit = 0}).

eap_handshake({start, _Data},
	      #data{eapol_state = {request, _}} = Data0) ->
    %% restart the handshake
    Data = stop_eapol_timer(Data0),
    init_eapol(Data);

eap_handshake(Data = {response, Id, EAPData, Response},
	      #data{eapol_state = {request, Id}} = Data0) ->
    lager:debug("EAP Handshake: ~p", [Data]),
    Data = stop_eapol_timer(Data0),
    Next =
	case Response of
	    {identity, Identity} ->
		%% Start ctld Authentication....
		Opts = [{'Username', Identity},
			{'Authentication-Method', 'EAP'},
			{'EAP-Data', EAPData}],
		{authenticate, Opts};

	    _ ->
		Opts = [{'EAP-Data', EAPData}],
		{authenticate, Opts}

	    %% _ ->
	    %%	{disassociation, []}
	end,
    eap_handshake_next(Next, Data);

eap_handshake(Data, Data0) ->
    lager:warning("unexpected EAP Handshake: ~p", [Data]),
    Data = stop_eapol_timer(Data0),
    wtp_del_station(Data),
    aaa_disassociation(Data),
    Data#data{eapol_state = undefined}.

eap_handshake_next({authenticate, Opts}, #data{aaa_session = Session} = Data) ->
    case ergw_aaa_session:authenticate(Session, to_session(Opts)) of
	success ->
	    lager:info("AuthResult: success"),

	    SessionOpts = ergw_aaa_session:get(Session),

	    case ergw_aaa_session:attr_get('EAP-Data', SessionOpts) of
		{ok, EAPData} ->
		    send_eapol(eapol:packet(EAPData), Data);
		_ ->
		    ok
	    end,

	    MSK = << (ergw_aaa_session:attr_get('MS-MPPE-Recv-Key', SessionOpts, <<>>))/binary,
		     (ergw_aaa_session:attr_get('MS-MPPE-Send-Key', SessionOpts, <<>>))/binary>>,
	    lager:debug("MSK: ~s", [capwap_tools:hexdump(MSK)]),
	    rsna_4way_handshake({init, MSK}, Data);

	challenge ->
	    lager:info("AuthResult: challenge"),
	    {ok, EAPData} = ergw_aaa_session:get(Session, 'EAP-Data'),
	    <<_Code:8, Id:8, _/binary>> = EAPData,
	    lager:info("EAP Challenge: ~p", [EAPData]),

	    send_eapol_packet(EAPData, Data#data{eapol_state = {request, Id}});

	Other ->
	    lager:info("AuthResult: ~p", [Other]),

	    case ergw_aaa_session:get(Session, 'EAP-Data') of
		{ok, EAPData} ->
		    send_eapol_packet(EAPData, Data);
		_ ->
		    ok
	    end,
	    wtp_del_station(Data),
	    aaa_disassociation(Data),
	    Data#data{eapol_state = undefined}
    end;

eap_handshake_next({disassociation, _}, Data) ->
    wtp_del_station(Data),
    aaa_disassociation(Data),
    Data#data{eapol_state = undefined}.

encode_gtk_ie(Tx, #ieee80211_key{index = Index, key = Key}) ->
    <<16#dd, (byte_size(Key) + 6):8,
      16#00, 16#0F, 16#AC, ?GTK_KDE:8,
      0:5, Tx:1, (Index + 1):2, 0, Key/binary>>.

encode_igtk_ie(#ieee80211_key{index = Index, key = Key}) ->
    <<16#dd, (byte_size(Key) + 12):8,
      16#00, 16#0F, 16#AC, ?IGTK_KDE:8,
      (Index + 4):16/little-integer, 0:48, Key/binary>>.

mic_for_akm('802.1x')			-> 'HMAC-SHA1-128';
mic_for_akm('PSK')			-> 'HMAC-SHA1-128';
mic_for_akm('FT-802.1x')		-> 'AES-128-CMAC';
mic_for_akm('FT-PSK')			-> 'AES-128-CMAC';
mic_for_akm('802.1x-SHA256')		-> 'AES-128-CMAC';
mic_for_akm('PSK-SHA256')		-> 'AES-128-CMAC';
mic_for_akm('802.1x-Suite-B')		-> 'HMAC-SHA256';
mic_for_akm('802.1x-Suite-B-192')	-> 'HMAC-SHA384';
mic_for_akm('FT-802.1x-SHA384')		-> 'HMAC-SHA384';
mic_for_akm(X)				-> X.

rsna_4way_handshake({init, MSK}, #data{capabilities =
					    #sta_cap{
					       rsn = #wtp_wlan_rsn{
							akm_suites = [AKM],
							group_mgmt_cipher_suite = GroupMgmtCipherSuite}}}
		    = Data) ->

    %% IEEE 802.11-2012, Sect. 11.6.1.3
    <<PMK:32/bytes, _/binary>> = MSK,

    ANonce = crypto:strong_rand_bytes(32),
    CipherData = #ccmp{akm_algo = AKM,
			mic_algo = mic_for_akm(AKM),
			group_mgmt_cipher_suite = GroupMgmtCipherSuite,
			replay_counter = 0,
			master_session_key = MSK,
			pre_master_key = PMK,
			nonce = ANonce},
    send_eapol_key([pairwise, ack], <<>>,
		   Data#data{eapol_state = init,
			     eapol_retransmit = 0,
			     rekey_running = ptk,
			     cipher_state = CipherData});

rsna_4way_handshake(rekey, Data = #data{eapol_state = installed,
					  cipher_state = CipherData0}) ->
    ANonce = crypto:strong_rand_bytes(32),
    CipherData = CipherData0#ccmp{nonce = ANonce},
    send_eapol_key([pairwise, ack], <<>>,
		   Data#data{eapol_state = init,
			     eapol_retransmit = 0,
			     cipher_state = CipherData});

rsna_4way_handshake({key, _Flags, MICAlgo, ReplayCounter, SNonce, KeyData, MICData},
		    Data0 = #data{radio_mac = BSS, mac = StationMAC,
				    wpa_config = #wpa_config{
						    ssid = SSID,
						    mobility_domain = MDomain,
						    rsn = #wtp_wlan_rsn{
							     management_frame_protection = MFP} = RSN},
				    gtk = GTK,
				    igtk = IGTK,
				    eapol_state = init,
				    cipher_state =
					#ccmp{
					   akm_algo = AKM,
					   mic_algo = MICAlgo,
					   group_mgmt_cipher_suite = GroupMgmtCipherSuite,
					   replay_counter = ReplayCounter,
					   master_session_key = MSK,
					   pre_master_key = PMK,
					   nonce = ANonce} = CipherData0})
  when AKM == 'FT-802.1x'; AKM == 'FT-PSK' ->
    %%
    %% Expected Msg: S1KH→R1KH: EAPOL-Key(0, 1, 0, 0, P, 0, 0, SNonce, MIC, RSNE[PMKR1Name], MDE, FTE)
    %%

    %% CipherSuite and ReplayCounter match...
    lager:debug("KeyData: ~p", [pbkdf2:to_hex(KeyData)]),
    lager:debug("PMK: ~p", [pbkdf2:to_hex(PMK)]),
    lager:debug("BSS: ~p", [pbkdf2:to_hex(BSS)]),
    lager:debug("StationMAC: ~p", [pbkdf2:to_hex(StationMAC)]),
    lager:debug("ANonce: ~p", [pbkdf2:to_hex(ANonce)]),
    lager:debug("SNonce: ~p", [pbkdf2:to_hex(SNonce)]),
    lager:debug("CipherData: ~p", [lager:pr(CipherData0, ?MODULE)]),
    Data = stop_eapol_timer(Data0),

    %%
    %% 802.11-2012, Sect. 11.6.6.3: 4-Way Handshake Message 2
    %%
    %%    Processing for PTK generation is as follows:
    %%
    %%    ...
    %%
    %%    On reception of Message 2, the Authenticator checks that the key
    %%    replay counter corresponds to the outstanding Message 1. If not,
    %%    it silently discards the message. Otherwise, the Authenticator:
    %%
    %%       a) Derives PTK.
    %%       b) Verifies the Message 2 MIC.
    %%       c)
    %%            1) If the calculated MIC does not match the MIC that the
    %%               Supplicant included in the EAPOL-Key frame, the
    %%               Authenticator silently discards Message 2.
    %%
    %%
    %% 802.11-2012, Sect. 12.4.2 FT initial mobility domain association in an RSN
    %%
    %%    The message sequence is similar to that of 11.6.6. The contents of
    %%    each message shall be as described in 11.6.6 except as follows:
    %%      - Message 2: the S1KH shall include the PMKR1Name in the PMKID field of
    %%        the RSNE. The PMKR1Name shall be as calculated by the S1KH according
    %%        to the procedures of 11.6.1.7.4; all other fields of the RSNE shall be
    %%        identical to the RSNE present in the (Re)Association Request frame. The
    %%        S1KH shall include the FTE and MDE; the FTE and MDE shall be the same as
    %%        those provided in the AP’s (Re)Association Response frame.
    %%
    R0KH = <<"scg4.tpip.net">>,
    {KCK, KEK, TK, _PMKR0Name, PMKR1Name} =
	eapol:ft_msk2ptk(MSK, SNonce, ANonce, BSS, StationMAC,
			 SSID, MDomain, R0KH, BSS, StationMAC, StationMAC),
    CipherData = CipherData0#ccmp{rsn = RSN, kck = KCK, kek = KEK, tk = TK},

    case eapol:validate_mic(CipherData, MICData) of
	ok ->
	    lager:debug("rsna_4way_handshake 2 of 4: ok"),
	    %% R1KH→S1KH: EAPOL-Key(1, 1, 1, 1, P, 0, 0, ANonce, MIC, RSNE[PMKR1Name], MDE,
	    %%                      GTK[N], IGTK[M], FTE, TIE[ReassociationDeadline],
	    %%                      TIE[KeyLifetime])

	    RSNIE = capwap_ac:rsn_ie(RSN, [PMKR1Name], MFP == required),
	    MDE = capwap_ac:ieee_802_11_ie(?WLAN_EID_MOBILITY_DOMAIN, <<MDomain:16, 1>>),
	    Tx = 0,
	    GTKIE = encode_gtk_ie(Tx, GTK),
	    IGTKIE = case GroupMgmtCipherSuite of
			 'AES-CMAC' ->
			     encode_igtk_ie(IGTK);
			 _ ->
			     <<>>
		     end,
	    FTE = ft_ie(R0KH, BSS),

	    %% TODO: possibly....
	    %%
	    %% IEEE 802.11 says ReassociationDeadline and KeyLifetime should be
	    %% present, but it seems to work without....
	    %%
	    %% TIEReassociationDeadLine = ti_ie(1, ReassociationDeadline),
	    %% TIEKeyLifetime = ti_ie(2, KeyLifetime),

	    TxKeyData = pad_key_data(<<RSNIE/binary, MDE/binary, GTKIE/binary,
				       IGTKIE/binary, FTE/binary>>),
				     %% TIEReassociationDeadLine/binary,
				     %% TIEKeyLifetime/binary>>),
	    lager:debug("TxKeyData: ~p", [pbkdf2:to_hex(TxKeyData)]),
	    EncTxKeyData = eapol:aes_key_wrap(KEK, TxKeyData),
	    lager:debug("EncTxKeyData: ~p", [pbkdf2:to_hex(EncTxKeyData)]),

	    send_eapol_key([pairwise, install, ack, mic, secure, enc], EncTxKeyData,
			   Data#data{eapol_state = install,
				     eapol_retransmit = 0,
				     cipher_state = CipherData});

	Other ->
	    lager:debug("rsna_4way_handshake FT 2 of 4: ~p", [Other]),
	    %% silently discard, see above
	    Data
    end;

rsna_4way_handshake({key, _Flags, MICAlgo, ReplayCounter, SNonce, KeyData, MICData},
		    Data0 = #data{radio_mac = BSS, mac = StationMAC,
				    capabilities = #sta_cap{last_rsne = LastRSNE},
				    wpa_config = #wpa_config{
						    rsn = #wtp_wlan_rsn{
							     management_frame_protection = MFP} = RSN},
				    gtk = GTK,
				    igtk = IGTK,
				    eapol_state = init,
				    cipher_state =
					#ccmp{
					   akm_algo = AKM,
					   mic_algo = MICAlgo,
					   group_mgmt_cipher_suite = GroupMgmtCipherSuite,
					   replay_counter = ReplayCounter,
					   pre_master_key = PMK,
					   nonce = ANonce} = CipherData0})
  when AKM == '802.1x'; AKM == 'PSK' ->
    %% CipherSuite and ReplayCounter match...
    lager:debug("KeyData: ~p", [pbkdf2:to_hex(KeyData)]),
    lager:debug("PMK: ~p", [pbkdf2:to_hex(PMK)]),
    lager:debug("BSS: ~p", [pbkdf2:to_hex(BSS)]),
    lager:debug("StationMAC: ~p", [pbkdf2:to_hex(StationMAC)]),
    lager:debug("ANonce: ~p", [pbkdf2:to_hex(ANonce)]),
    lager:debug("SNonce: ~p", [pbkdf2:to_hex(SNonce)]),
    lager:debug("CipherData: ~p", [lager:pr(CipherData0, ?MODULE)]),
    Data = stop_eapol_timer(Data0),

    %%
    %% 802.11-2012, Sect. 11.6.6.3: 4-Way Handshake Message 2
    %%
    %%    Processing for PTK generation is as follows:
    %%
    %%    ...
    %%
    %%    On reception of Message 2, the Authenticator checks that the key
    %%    replay counter corresponds to the outstanding Message 1. If not,
    %%    it silently discards the message. Otherwise, the Authenticator:
    %%
    %%       a) Derives PTK.
    %%       b) Verifies the Message 2 MIC.
    %%       c)
    %%            1) If the calculated MIC does not match the MIC that the
    %%               Supplicant included in the EAPOL-Key frame, the
    %%               Authenticator silently discards Message 2.
    %%

    {KCK, KEK, TK} = eapol:pmk2ptk(PMK, BSS, StationMAC, ANonce, SNonce, 384),
    lager:debug("KCK: ~p", [pbkdf2:to_hex(KCK)]),
    lager:debug("KEK: ~p", [pbkdf2:to_hex(KEK)]),
    lager:debug("TK: ~p", [pbkdf2:to_hex(TK)]),

    CipherData = CipherData0#ccmp{rsn = RSN, kck = KCK, kek = KEK, tk = TK},

    case {eapol:validate_mic(CipherData, MICData), KeyData} of
	{ok, <<?WLAN_EID_RSN, RSNLen:8, LastRSNE:RSNLen/bytes, _/binary>>} ->
	    lager:debug("rsna_4way_handshake 2 of 4: ok"),
	    RSNIE = capwap_ac:rsn_ie(RSN, MFP == required),
	    Tx = 0,
	    GTKIE = encode_gtk_ie(Tx, GTK),
	    IGTKIE = case GroupMgmtCipherSuite of
			 'AES-CMAC' ->
			     encode_igtk_ie(IGTK);
			 _ ->
			     <<>>
		     end,
	    TxKeyData = pad_key_data(<<RSNIE/binary, GTKIE/binary, IGTKIE/binary>>),
	    lager:debug("TxKeyData: ~p", [pbkdf2:to_hex(TxKeyData)]),
	    EncTxKeyData = eapol:aes_key_wrap(KEK, TxKeyData),
	    lager:debug("EncTxKeyData: ~p", [pbkdf2:to_hex(EncTxKeyData)]),

	    send_eapol_key([pairwise, install, ack, mic, secure, enc], EncTxKeyData,
			   Data#data{eapol_state = install,
				     eapol_retransmit = 0,
				     cipher_state = CipherData});

	{ok, _} ->
	    %% MIC is ok, but RSNE does not match
	    lager:debug("rsna_4way_handshake 2 of 4: MIC ok, RSNE don't match (~p != ~p)",
		       [pbkdf2:to_hex(KeyData), pbkdf2:to_hex(LastRSNE)]),
	    wtp_del_station(Data),
	    aaa_disassociation(Data),
	    Data#data{eapol_state = undefined, cipher_state = undefined};

	Other ->
	    lager:debug("rsna_4way_handshake 2 of 4: ~p", [Other]),
	    %% silently discard, see above
	    Data
    end;

rsna_4way_handshake({key, _Flags, _CipherSuite, ReplayCounter, _SNonce, _KeyData, MICData},
		    Data0 = #data{ac = AC, radio_mac = BSS, mac = StationMAC, capabilities = Caps,
				    eapol_state = install,
				    cipher_state =
					#ccmp{
					   replay_counter = ReplayCounter} = CipherData}) ->
    Data = stop_eapol_timer(Data0),

    %%
    %% 802.11-2012, Sect. 11.6.6.5: 4-Way Handshake Message 4
    %%
    %%    Processing for PTK generation is as follows:
    %%
    %%    ...
    %%
    %%    On reception of Message 4, the Authenticator verifies that the Key
    %%    Replay Counter field value is one that it used on this 4-Way Handshake;
    %%    if it is not, it silently discards the message. Otherwise:
    %%
    %%       a) The Authenticator checks the MIC. If the calculated MIC does not
    %%          match the MIC that the Supplicant included in the EAPOL-Key frame,
    %%          the Authenticator silently discards Message 4.
    %%

    case eapol:validate_mic(CipherData, MICData) of
	ok ->
	    lager:debug("rsna_4way_handshake 4 of 4: ok"),
	    capwap_ac:add_station(AC, BSS, StationMAC, Caps, {false, true, CipherData}),
	    rekey_done(ptk, Data#data{eapol_state = installed});

	Other ->
	    lager:debug("rsna_4way_handshake 4 of 4: ~p", [Other]),
	    %% silently discard, see above
	    Data
    end;

rsna_4way_handshake(Frame, Data) ->
    lager:warning("got unexpexted EAPOL data in 4way Handshake: ~p", [Frame]),
    %% silently discard, both Message 2 and Message are handles this way
    Data.

rsna_2way_handshake(rekey, Data = #data{eapol_state = installed,
					  cipher_state = #ccmp{
							    group_mgmt_cipher_suite = GroupMgmtCipherSuite,
							    kek = KEK},
					  gtk = GTK, igtk = IGTK}) ->
    %% EAPOL-Key(1,1,1,0,G,0,Key RSC,0, MIC,GTK[N],IGTK[M])

    Tx = 0,
    GTKIE = encode_gtk_ie(Tx, GTK),
    IGTKIE = case GroupMgmtCipherSuite of
		 'AES-CMAC' ->
		     encode_igtk_ie(IGTK);
		 _ ->
		     <<>>
	     end,
    TxKeyData = pad_key_data(<<GTKIE/binary, IGTKIE/binary>>),
    EncTxKeyData = eapol:aes_key_wrap(KEK, TxKeyData),
    lager:debug("TxKeyData: ~p", [pbkdf2:to_hex(TxKeyData)]),
    lager:debug("EncTxKeyData: ~p", [pbkdf2:to_hex(EncTxKeyData)]),

    send_eapol_key([group, ack, mic, secure, enc], EncTxKeyData,
		   Data#data{eapol_state = install,
			     eapol_retransmit = 0});

rsna_2way_handshake({key, _Flags, _MICAlgo, ReplayCounter, _SNonce, _KeyData, MICData},
		    Data0 = #data{eapol_state = install,
				    rekey_control = RekeyCtl,
				    cipher_state =
					#ccmp{
					   replay_counter = ReplayCounter} = CipherData}) ->
    %% EAPOL-Key(1,1,0,0,G,0,0,0,MIC,0)
    Data = stop_eapol_timer(Data0),
    capwap_ac_gtk_rekey:gtk_rekey_done(RekeyCtl, self()),

    case eapol:validate_mic(CipherData, MICData) of
	ok ->
	    lager:debug("rsna_2way_handshake 2 of 2: ok"),
	    rekey_done(gtk, Data#data{eapol_state = installed});

	Other ->
	    lager:debug("rsna_2way_handshake 2 of 2: ~p", [Other]),
	    wtp_del_station(Data),
	    aaa_disassociation(Data),
	    Data#data{eapol_state = undefined, cipher_state = undefined}
    end;

rsna_2way_handshake(Frame, Data) ->
    lager:warning("got unexpexted EAPOL data in 2way Handshake: ~p", [Frame]),
    Data.

pad_key_data(KD) when byte_size(KD) < 15 ->
    pad_to(16, <<KD/binary, 16#dd>>);
pad_key_data(KD) when byte_size(KD) rem 8 /= 0 ->
    pad_to(8, <<KD/binary, 16#dd>>);
pad_key_data(KD) ->
    KD.

rekey_timer_start(ptk, #data{wpa_config = #wpa_config{peer_rekey = Interval},
			      rekey_tref = undefined} = Data)
  when is_integer(Interval) andalso Interval > 0 ->
    lager:debug("Starting rekey for PTK in ~w", [Interval]),
    TRef = erlang:send_after(Interval * 1000, self(), {rekey, ptk}),
    Data#data{rekey_tref = TRef};
rekey_timer_start(_Type, Data) ->
    Data.

rekey_timer_stop(ptk, #data{rekey_tref = TRef} = Data)
  when is_reference(TRef) ->
    cancel_timer(TRef),
    Data#data{rekey_tref = undefined};
rekey_timer_stop(_Type, Data) ->
    Data.

rekey_timer_start(Data) ->
    lists:foldl(fun rekey_timer_start/2, Data, [ptk]).

rekey_done(_Type, Data0) ->
    Data = rekey_timer_start(Data0#data{rekey_running = false}),
    case Data#data.rekey_pending of
	[Next | Pending] ->
	    rekey_init(Next, Data#data{rekey_pending = Pending});
	_ ->
	    Data#data{rekey_pending = []}
    end.

rekey_init(ptk, Data) ->
    rsna_4way_handshake(rekey, Data#data{rekey_running = ptk});
rekey_init(gtk, Data) ->
    rsna_2way_handshake(rekey, Data#data{rekey_running = gtk});
rekey_init(Type, Data) ->
    rekey_done(Type, Data).

rekey_start(Type, Data0 = #data{rekey_running = false}) ->
    Data = rekey_timer_stop(Type, Data0),
    rekey_init(Type, Data);
rekey_start(Type, Data = #data{rekey_pending = Pending}) ->
    rekey_timer_stop(Type, Data#data{rekey_pending = [Type, Pending]}).
