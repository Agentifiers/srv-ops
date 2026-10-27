#!/opt/pymobiledevice3/bin/python
"""pymobiledevice3 operations the CLI does not offer, run by iphone_broker.py as a subprocess
(one device session per call, killed on timeout like every other device command).

  pmd3_helper.py launch UDID BUNDLE_ID [--arg A]... [--env K=V]... [--url URL] [--no-kill-existing]
                 [--console-seconds N]
      CoreDevice launchapplication. --url is delivered as the launch's payload URL (what
      `devicectl device process launch --payload-url` sends: options.payloadURL = {"relative": URL}),
      so the app gets it as its open-URL / deep link. Prints the launch result as one JSON line,
      then, with --console-seconds, the app's stdout/stderr for that long.

  pmd3_helper.py keepawake UDID SECONDS
      Holds PreventUserIdleDisplaySleep + PreventUserIdleSystemSleep power assertions
      (com.apple.mobile.assertion_agent) for SECONDS, then exits.
"""
import argparse
import asyncio
import json
import plistlib
import sys
from contextlib import AsyncExitStack

from pymobiledevice3.remote.core_device.app_service import AppServiceService
from pymobiledevice3.remote.core_device.open_stdio_socket import OpenStdioSocketService
from pymobiledevice3.services.power_assertion import PowerAssertionService
from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid


async def rsd_for(udid):
    rsd = await get_tunneld_device_by_udid(udid)
    if rsd is None:
        sys.exit(f"device {udid} has no tunnel (pmd3-tunneld)")
    return rsd


async def launch(a):
    rsd = await rsd_for(a.udid)
    options = {
        "arguments": a.arg,
        "environmentVariables": dict(kv.split("=", 1) for kv in a.env),
        "standardIOUsesPseudoterminals": True,
        "startStopped": False,
        "terminateExisting": not a.no_kill_existing,
        "user": {"shortName": "mobile"},
        "platformSpecificOptions": plistlib.dumps({}),
    }
    if a.url:
        options["payloadURL"] = {"relative": a.url}
    async with AsyncExitStack() as stack:
        apps = await stack.enter_async_context(AppServiceService(rsd))
        stdio = None
        if a.console_seconds > 0:
            stdio = await stack.enter_async_context(OpenStdioSocketService(rsd))
            ids = dict.fromkeys(("standardInput", "standardOutput", "standardError"), stdio.identifier)
        else:
            ids = {}
        result = await apps.invoke(
            "com.apple.coredevice.feature.launchapplication",
            {"applicationSpecifier": {"bundleIdentifier": {"_0": a.bundle_id}}, "options": options,
             "standardIOIdentifiers": ids},
        )
        token = (result or {}).get("processToken", {})
        print(json.dumps({"pid": token.get("processIdentifier"), "bundle_id": a.bundle_id, "url": a.url}), flush=True)
        if stdio is None:
            return

        async def pump():
            while chunk := await stdio.read():
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()

        try:
            await asyncio.wait_for(pump(), a.console_seconds)
        except asyncio.TimeoutError:
            pass


async def keepawake(a):
    rsd = await rsd_for(a.udid)
    async with AsyncExitStack() as stack:
        for kind in ("PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"):
            svc = PowerAssertionService(rsd)
            await stack.enter_async_context(svc.create_power_assertion(kind, "iphone-broker", a.seconds))
        print("assertions held", flush=True)
        await asyncio.sleep(a.seconds)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("launch")
    p.add_argument("udid")
    p.add_argument("bundle_id")
    p.add_argument("--arg", action="append", default=[])
    p.add_argument("--env", action="append", default=[])
    p.add_argument("--url")
    p.add_argument("--no-kill-existing", action="store_true")
    p.add_argument("--console-seconds", type=float, default=0)
    p = sub.add_parser("keepawake")
    p.add_argument("udid")
    p.add_argument("seconds", type=int)
    a = ap.parse_args()
    asyncio.run({"launch": launch, "keepawake": keepawake}[a.cmd](a))


if __name__ == "__main__":
    main()
