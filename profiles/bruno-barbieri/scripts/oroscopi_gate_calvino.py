#!/usr/bin/env python3
# Cron gate for the calvino review job on viral-sites/oroscopi (see bruno-barbieri/scripts/oroscopi_gate.py)
import runpy, sys
sys.argv = ["oroscopi_gate.py", "calvino"]
runpy.run_path("/opt/data/profiles/bruno-barbieri/scripts/oroscopi_gate.py", run_name="__main__")
