# Cleans accidentally set WiFi interworking fields from RouterOS 7 WiFi items.
#
# Recommended before running:
#   /export file=before-wifi-interworking-cleanup
#
# The script only unsets a field when that field is present on a WiFi item,
# including empty values like interworking.realms-raw="". It does not remove
# entries from /interface wifi interworking.

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

:foreach item in=[/interface wifi print as-value] do={
    :local id ($item->".id")
    :local itemText [:tostr $item]
    :foreach p in=$iwProps do={
        :local hasProp false
        :if ([:typeof ($item->$p)] != "nil") do={
            :set hasProp true
        }
        :if ($hasProp = false) do={
            :if ([:typeof [:find $itemText ($p . "=")]] != "nil") do={
                :set hasProp true
            }
        }

        :if ($hasProp = true) do={
            :onerror e in={
                :local v ($item->$p)
                :put ("unset /interface wifi " . $id . " " . $p . "=" . [:tostr $v])
                :local cmd [:parse ("/interface wifi set " . $id . " !" . $p)]
                $cmd
                :set cleaned ($cleaned + 1)
            } do={}
        }
    }
}

:foreach item in=[/interface wifi configuration print as-value] do={
    :local id ($item->".id")
    :local itemText [:tostr $item]
    :foreach p in=$iwProps do={
        :local hasProp false
        :if ([:typeof ($item->$p)] != "nil") do={
            :set hasProp true
        }
        :if ($hasProp = false) do={
            :if ([:typeof [:find $itemText ($p . "=")]] != "nil") do={
                :set hasProp true
            }
        }

        :if ($hasProp = true) do={
            :onerror e in={
                :local v ($item->$p)
                :put ("unset /interface wifi configuration " . $id . " " . $p . "=" . [:tostr $v])
                :local cmd [:parse ("/interface wifi configuration set " . $id . " !" . $p)]
                $cmd
                :set cleaned ($cleaned + 1)
            } do={}
        }
    }
}

:put ("Cleanup complete. Fields unset: " . $cleaned)
:put "After cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"
