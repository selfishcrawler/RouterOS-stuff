# Cleans accidentally set WiFi interworking fields from RouterOS 7 WiFi items.
#
# Recommended before running:
#   /export file=before-wifi-interworking-cleanup
#
# The script only unsets a field when that field currently returns a non-empty
# value. It does not remove entries from /interface wifi interworking.

:put "Before cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"

:local iwProps {
    "interworking";
    "interworking.disabled";
    "interworking.asra";
    "interworking.esr";
    "interworking.hessid";
    "interworking.internet";
    "interworking.network-type";
    "interworking.uesa";
    "interworking.venue";
    "interworking.3gpp-info";
    "interworking.3gpp-raw";
    "interworking.authentication-types";
    "interworking.connection-capabilities";
    "interworking.domain-names";
    "interworking.ipv4-availability";
    "interworking.ipv6-availability";
    "interworking.realms";
    "interworking.realms-raw";
    "interworking.roaming-ois";
    "interworking.venue-names";
    "interworking.hotspot20";
    "interworking.hotspot20-dgaf";
    "interworking.operational-classes";
    "interworking.operator-names";
    "interworking.wan-at-capacity";
    "interworking.wan-downlink";
    "interworking.wan-downlink-load";
    "interworking.wan-measurement-duration";
    "interworking.wan-status";
    "interworking.wan-symmetric";
    "interworking.wan-uplink";
    "interworking.wan-uplink-load"
}

:local cleaned 0

:foreach id in=[/interface wifi find] do={
    :foreach p in=$iwProps do={
        :onerror e in={
            :local v [/interface wifi get $id value-name=$p]
            :if ([:len [:tostr $v]] > 0) do={
                :put ("unset /interface wifi " . $id . " " . $p . "=" . $v)
                :local cmd [:parse ("/interface wifi set " . $id . " !" . $p)]
                $cmd
                :set cleaned ($cleaned + 1)
            }
        } do={}
    }
}

:foreach id in=[/interface wifi configuration find] do={
    :foreach p in=$iwProps do={
        :onerror e in={
            :local v [/interface wifi configuration get $id value-name=$p]
            :if ([:len [:tostr $v]] > 0) do={
                :put ("unset /interface wifi configuration " . $id . " " . $p . "=" . $v)
                :local cmd [:parse ("/interface wifi configuration set " . $id . " !" . $p)]
                $cmd
                :set cleaned ($cleaned + 1)
            }
        } do={}
    }
}

:put ("Cleanup complete. Fields unset: " . $cleaned)
:put "After cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"
