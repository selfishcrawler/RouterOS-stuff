# Cleans accidentally set WiFi interworking fields from RouterOS 7 WiFi items.
#
# Recommended before running:
#   /export file=before-wifi-interworking-cleanup
#
# The script checks each known interworking field with :grep against
# /interface wifi export terse. If the field is visible in export, it unsets
# that field from all WiFi interfaces and WiFi configuration profiles. It does
# not remove entries from /interface wifi interworking.

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

:local found 0
:local skipped 0

:foreach prop in=$iwProps do={
    :local pattern (" " . $prop . "=")
    :local grepScript (":grep pattern=\"" . $pattern . "\" script=\"/interface wifi export terse\"")
    :local grepResult [:execute script=$grepScript as-string]

    :if ([:len [:tostr $grepResult]] > 0) do={
        :put ("found " . $prop . ", unsetting")

        :onerror e in={
            :local cmd [:parse ("/interface wifi set [find] !" . $prop)]
            $cmd
        } do={}

        :onerror e in={
            :local cmd [:parse ("/interface wifi configuration set [find] !" . $prop)]
            $cmd
        } do={}

        :set found ($found + 1)
    } else={
        :put ("skip " . $prop)
        :set skipped ($skipped + 1)
    }
}

:put ("Cleanup complete. Fields found: " . $found . "; skipped: " . $skipped)
:put "After cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"
