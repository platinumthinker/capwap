REST HTTP API
=============

Settings for http api in sys.config:
```erlang
[{capwap, [
    {http_api, [
        {ip, {127, 0, 0, 1}},
        {port, 8000},
        {acceptors_num, 100}
 ]
]
```

Swagger is available in path: ```http://SERVER/api/v1/spec/ui```

general commands
----------------

* /api/v1/version: get

    return CAPWAP release version

wtp commands
---------------

* /api/v1/wtp: get

    list all registered wtps

* /api/v1/wtp/{id}: get

    show wtp information

* /api/v1/wtp/{id}/update/{link}/{hash}: post

    update wtp

* /api/v1/wtp/{id}/set-ssid/{ssid}/[{radio_id}]: post

    set ssid for wtp. (radio_id is not require. default: 1)

* /api/v1/wtp/{id}/stop-radio/{radio_id}: delete

    stop wifi radio

station commands
----------------

* /api/v1/station: get

    list all know station

* /api/v1/station/{mac}: delete

    detach station from WLAN

dp commands
-----------

* /api/v1/dp/wtp-list: get

    list all WTP's with active data path

* /api/v1/dp/stats: get

    show data path statistics
