# Cleans accidentally set WiFi interworking fields from RouterOS 7 WiFi items.
#
# Recommended before running:
#   /export file=before-wifi-interworking-cleanup
#
# The script uses /interface wifi export terse as the source of truth. It only
# unsets fields that are visible in export, including empty values like
# interworking.realms-raw="". It does not remove entries from
# /interface wifi interworking.

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

:local contains do={
    :local text [:tostr $1]
    :local needle [:tostr $2]
    :return ([:len [:tostr [:find $text $needle]]] > 0)
}

:local getToken do={
    :local line [:tostr $1]
    :local key [:tostr $2]
    :local marker (" " . $key . "=")
    :local pos [:find $line $marker]

    :if ([:len [:tostr $pos]] = 0) do={
        :return ""
    }

    :local start ($pos + [:len $marker])
    :local first [:pick $line $start ($start + 1)]

    :if ($first = "\"") do={
        :local end [:find $line "\"" ($start + 1)]
        :if ([:len [:tostr $end]] = 0) do={
            :return ""
        }
        :return [:pick $line ($start + 1) $end]
    }

    :local end [:find $line " " $start]
    :if ([:len [:tostr $end]] = 0) do={
        :set end [:len $line]
    }

    :return [:pick $line $start $end]
}

:local exportText [:execute script="/interface wifi export terse" as-string]
:local remaining $exportText
:local cleaned 0
:local skipped 0

:while ([:len $remaining] > 0) do={
    :local lineEnd [:find $remaining "\n"]
    :local line ""

    :if ([:len [:tostr $lineEnd]] = 0) do={
        :set line $remaining
        :set remaining ""
    } else={
        :set line [:pick $remaining 0 $lineEnd]
        :set remaining [:pick $remaining ($lineEnd + 1) [:len $remaining]]
    }

    :if ([$contains $line "interwork"] = true) do={
        :local menu ""
        :if ([$contains $line "/interface wifi configuration "] = true) do={
            :set menu "configuration"
        }
        :if (($menu = "") && ([$contains $line "/interface wifi "] = true)) do={
            :if ([$contains $line "/interface wifi interworking"] = false) do={
                :set menu "wifi"
            }
        }

        :if ([:len $menu] > 0) do={
            :local itemName [$getToken $line "name"]
            :local defaultName [$getToken $line "default-name"]

            :foreach prop in=$iwProps do={
                :if ([$contains $line (" " . $prop . "=")] = true) do={
                    :local matched false

                    :if ($menu = "configuration") do={
                        :if ([:len $itemName] > 0) do={
                            :foreach id in=[/interface wifi configuration find where name=$itemName] do={
                                :onerror e in={
                                    :local cmd [:parse ("/interface wifi configuration set " . $id . " !" . $prop)]
                                    $cmd
                                    :put ("unset /interface wifi configuration " . $id . " " . $prop)
                                    :set cleaned ($cleaned + 1)
                                    :set matched true
                                } do={}
                            }
                        }
                    }

                    :if ($menu = "wifi") do={
                        :if ([:len $itemName] > 0) do={
                            :foreach id in=[/interface wifi find where name=$itemName] do={
                                :onerror e in={
                                    :local cmd [:parse ("/interface wifi set " . $id . " !" . $prop)]
                                    $cmd
                                    :put ("unset /interface wifi " . $id . " " . $prop)
                                    :set cleaned ($cleaned + 1)
                                    :set matched true
                                } do={}
                            }
                        }

                        :if (($matched = false) && ([:len $defaultName] > 0)) do={
                            :foreach id in=[/interface wifi find where default-name=$defaultName] do={
                                :onerror e in={
                                    :local cmd [:parse ("/interface wifi set " . $id . " !" . $prop)]
                                    $cmd
                                    :put ("unset /interface wifi " . $id . " " . $prop)
                                    :set cleaned ($cleaned + 1)
                                    :set matched true
                                } do={}
                            }
                        }
                    }

                    :if ($matched = false) do={
                        :put ("skip " . $menu . " " . $prop . ": could not match export line to an item")
                        :set skipped ($skipped + 1)
                    }
                }
            }
        }
    }
}

:put ("Cleanup complete. Fields unset: " . $cleaned . "; skipped: " . $skipped)
:put "After cleanup:"
:grep pattern="interwork" script="/interface wifi export terse"
