# Clean WiFi interworking fields

`cleanup-wifi-interworking.rsc` removes accidentally added `interworking.*`
settings from RouterOS 7 WiFi interfaces and WiFi configuration profiles.

## Why This Exists

Some RouterOS 7 builds can add `interworking` fields after WiFi configuration is
edited from Winbox 3. The unwanted fields then show up in exports, for example:

```routeros
:grep pattern="interwork" script="/interface wifi export terse"
```

If you do not use WiFi Interworking or Hotspot 2.0, these fields are usually
noise and can be unset from the affected `/interface wifi` and
`/interface wifi configuration` items.

## What It Does

The script:

1. Prints matching `interwork` lines before cleanup.
2. Checks known `interworking.*` properties on every `/interface wifi` item.
3. Checks the same properties on every `/interface wifi configuration` item.
4. Runs `set <id> !<property>` only when that exact property currently has a
   non-empty value.
5. Prints each unset operation and a final count.
6. Prints matching `interwork` lines after cleanup.

It does not delete objects from `/interface wifi interworking`.

## Important Warning

Do not run this script if you intentionally use WiFi Interworking or Hotspot
2.0 settings on your RouterOS device. It is designed to remove those fields
from WiFi interfaces and WiFi configuration profiles.

## Backup First

Create an export before running the cleanup:

```routeros
/export file=before-wifi-interworking-cleanup
```

You can also inspect the affected lines first:

```routeros
:grep pattern="interwork" script="/interface wifi export terse"
```

## Preferred Run Method: Fetch from GitHub

The most convenient one-time run method is to fetch the raw script from GitHub
into memory and execute it immediately:

```routeros
{
    :local url "https://raw.githubusercontent.com/selfishcrawler/RouterOS-stuff/main/scripts/cleanup-wifi-interworking/cleanup-wifi-interworking.rsc"
    :local result [/tool fetch url=$url output=user as-value check-certificate=yes-without-crl]
    :if (($result->"status") != "finished") do={
        :error ("fetch failed: " . ($result->"status"))
    }

    :local script ($result->"data")
    :if ([:len $script] = 0) do={
        :error "fetch returned an empty script"
    }

    :local run [:parse $script]
    $run
}
```

This uses `output=user as-value`, so RouterOS puts the downloaded script into
the returned `data` value instead of saving it as a file. That avoids an extra
write to router storage and is a good fit for small one-off cleanup scripts.

RouterOS keeps `output=user` data in a variable, so the downloaded content must
fit the RouterOS variable limit. This script is intentionally small enough for
that.

For maximum repeatability, inspect the current script on GitHub before running
it, or pin the URL to a specific commit instead of `main`.

If certificate validation fails, check the router date/time and certificate
store. As a fallback, use the paste-into-terminal method below after reviewing
the script contents.

## Alternative: Paste into Terminal

You can also open a RouterOS terminal and paste the full contents of
`cleanup-wifi-interworking.rsc` directly into it. You do not need to upload the
file to the router first.

This is useful when the router does not have internet access or when you want
to review every line locally before execution.

## Alternative: Import the File

If you prefer file-based execution, upload `cleanup-wifi-interworking.rsc` to
the router and import it:

```routeros
/import file-name=cleanup-wifi-interworking.rsc
```

## Run from System Script

Create a temporary system script with `policy=read,write,test`, paste the
contents of `cleanup-wifi-interworking.rsc`, run it once, then remove the
temporary script if you no longer need it.

## How Unset Works

RouterOS uses `!property` in a `set` command to unset a property. For example:

```routeros
/interface wifi set *1 !interworking.internet
```

This `.rsc` file builds that command dynamically because the property name is
taken from a list:

```routeros
:local cmd [:parse ("/interface wifi set " . $id . " !" . $p)]
$cmd
```

Before building the unset command, it checks the current value:

```routeros
:local v [/interface wifi get $id value-name=$p]
:if ([:len [:tostr $v]] > 0) do={ ... }
```

That way, a test configuration with only one `interworking.*` property set
should produce only one unset operation instead of clearing every known
interworking property name.

## Checked Properties

The script checks these properties:

```text
interworking
interworking.disabled
interworking.asra
interworking.esr
interworking.hessid
interworking.internet
interworking.network-type
interworking.uesa
interworking.venue
interworking.3gpp-info
interworking.3gpp-raw
interworking.authentication-types
interworking.connection-capabilities
interworking.domain-names
interworking.ipv4-availability
interworking.ipv6-availability
interworking.realms
interworking.realms-raw
interworking.roaming-ois
interworking.venue-names
interworking.hotspot20
interworking.hotspot20-dgaf
interworking.operational-classes
interworking.operator-names
interworking.wan-at-capacity
interworking.wan-downlink
interworking.wan-downlink-load
interworking.wan-measurement-duration
interworking.wan-status
interworking.wan-symmetric
interworking.wan-uplink
interworking.wan-uplink-load
```

## Troubleshooting

### Nothing changed

Run the grep command manually and confirm that the exported lines include
`interwork`. If the fields are not on `/interface wifi` or
`/interface wifi configuration`, this script will only report the before/after
output.

### The script reports an error while reading a property

Unsupported or missing properties are ignored. This allows the same script to
run across RouterOS versions where the exact property list can differ.

### WiFi Interworking settings disappeared

Restore the needed settings from your backup export. This script is for devices
where those fields were added accidentally and are not intentionally used.
