# RouterOS stuff

Utilities, scripts, and notes for MikroTik RouterOS and Cloud Hosted Router
(CHR) work.

This repository is meant to grow as a collection of small, focused RouterOS
tools. Each tool lives in its own directory with its own README so the project
root can stay useful as an index instead of becoming one large manual.

## Tools

| Tool | Description |
| --- | --- |
| [Convert MikroTik CHR VHDX for Hyper-V Generation 2](scripts/convert-mikrotik-chr-vhdx-gen2/) | Patches a copy of a MikroTik CHR VHDX image so it can boot as a Hyper-V Generation 2 VM. |
| [Clean WiFi interworking fields](scripts/cleanup-wifi-interworking/) | Removes accidentally exported `interworking.*` fields from RouterOS WiFi interfaces and configuration profiles. |

## Layout

```text
scripts/
  <tool-name>/
    README.md
    <tool files>
```

Read the README inside a tool directory before running it. Some tools can touch
disk images, virtual machines, or RouterOS devices, so their requirements and
safety notes live next to the code.
