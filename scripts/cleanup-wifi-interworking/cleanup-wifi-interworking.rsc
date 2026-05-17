# Cleans accidentally set WiFi interworking fields from RouterOS 7 WiFi items.
#
# Recommended before running:
#   /export file=before-wifi-interworking-cleanup
#
# The script checks each known interworking field with :grep against each WiFi
# item export. If the field is visible on a specific WiFi interface or
# configuration profile, it unsets that field only from that item. It does not
# remove entries from /interface wifi interworking.

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

:local fieldsFound 0
:local objectsCleaned 0
:local skipped 0

:foreach prop in=$iwProps do={
    :local pattern (" " . $prop . "=")
    :local propHits 0

    :foreach id in=[/interface wifi find] do={
        :local itemName [/interface wifi get $id name]
        :local exportScript ("/interface wifi export terse where name=" . $itemName)
        :local grepScript (":grep pattern=\"" . $pattern . "\" script=\"" . $exportScript . "\"")
        :local grepResult [:execute script=$grepScript as-string]

        :if ([:len [:tostr $grepResult]] > 0) do={
            :onerror e in={
                :local cmd [:parse ("/interface wifi set " . $id . " !" . $prop)]
                $cmd
                :put ("unset /interface wifi " . $id . " " . $prop)
                :set propHits ($propHits + 1)
                :set objectsCleaned ($objectsCleaned + 1)
            } do={}
        }
    }

    :foreach id in=[/interface wifi configuration find] do={
        :local itemName [/interface wifi configuration get $id name]
        :local exportScript ("/interface wifi configuration export terse where name=" . $itemName)
        :local grepScript (":grep pattern=\"" . $pattern . "\" script=\"" . $exportScript . "\"")
        :local grepResult [:execute script=$grepScript as-string]

        :if ([:len [:tostr $grepResult]] > 0) do={
            :onerror e in={
                :local cmd [:parse ("/interface wifi configuration set " . $id . " !" . $prop)]
                $cmd
                :put ("unset /interface wifi configuration " . $id . " " . $prop)
                :set propHits ($propHits + 1)
                :set objectsCleaned ($objectsCleaned + 1)
            } do={}
        }
    }

    :if ($propHits > 0) do={
        :put ("found " . $prop . " on " . $propHits . " item(s)")
        :set fieldsFound ($fieldsFound + 1)
    } else={
        :put ("skip " . $prop)
        :set skipped ($skipped + 1)
    }
}

:put ("Cleanup complete. Fields found: " . $fieldsFound . "; objects cleaned: " . $objectsCleaned . "; skipped: " . $skipped)
:put "After cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"
