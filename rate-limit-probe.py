#!/usr/bin/env python3
"""
Claude Code Rate Limit Probe
Spawns a claude CLI session via PTY, navigates to /status -> Usage tab,
parses rate limit data, and writes to a JSON cache file.
"""
import subprocess, os, sys, time, select, pty, re, json

CACHE_FILE = os.path.expanduser("~/.claude/rate-limit-cache.json")
LOCK_FILE = CACHE_FILE + ".lock"

def read_all(fd, timeout_s):
    buf = b""
    start = time.time()
    while time.time() - start < timeout_s:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                data = os.read(fd, 8192)
                if data:
                    buf += data
                else:
                    break
            except:
                break
    return buf

def clean_ansi(raw_bytes):
    text = raw_bytes.decode('utf-8', errors='replace')
    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', text)
    text = re.sub(r'\x1b\][^\x07]*\x07', '', text)
    text = re.sub(r'\x1b[^[\]].?', '', text)
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
    return text

def parse_usage(text):
    """Parse rate limit usage from cleaned /status Usage tab output.

    The output has this structure (with possible ANSI artifacts):
      Current session    ...  43% used
      Resets 7pm (Asia/Shanghai)
      Current week (all models)
      ...  80% used
      Resets 10am (Asia/Shanghai)
      Current week (Sonnet only)
      ...  32% used
      Resets 10am (Asia/Shanghai)
    """
    result = {}

    # Grab all "XX% used" and "Resets TIME" in order
    # Handles "Resets 8pm", "Resets Mar 30 at 11am", and spaceless TUI output "ResetsMar30at11am"
    all_pcts = re.findall(r'(\d+)%\s*used', text)
    all_resets = re.findall(r'Rese[ts]*\s*(?:([A-Za-z]{3,})\s*(\d{1,2})\s*(?:at\s*)?)?\s*(\d{1,2})\s*([ap]m)', text, re.IGNORECASE)

    # Assign by position: [0]=session, [1]=week_all, [2]=week_sonnet
    if len(all_pcts) >= 1:
        result['session_pct'] = int(all_pcts[0])
    if len(all_pcts) >= 2:
        result['week_all_pct'] = int(all_pcts[1])
    if len(all_pcts) >= 3:
        result['week_sonnet_pct'] = int(all_pcts[2])

    def enrich_reset(match_tuple):
        """Convert regex match (month, day, hour, ampm) to display string.
        month/day may be empty for simple '8pm' format."""
        import datetime
        month_str, day_str, hour_str, ampm = match_tuple
        hour = int(hour_str)
        if ampm.lower() == 'pm' and hour != 12:
            hour += 12
        elif ampm.lower() == 'am' and hour == 12:
            hour = 0
        h24 = f"{hour}:00"

        if month_str:
            # Future date reset: "Mar 30 at 11am" → "Mar30 11:00"
            return f"{month_str}{day_str} {h24}"

        # Same-day/next-day reset: "8pm" → "today 20:00" or "Tue 20:00"
        now = datetime.datetime.now()
        reset_today = now.replace(hour=hour, minute=0, second=0, microsecond=0)
        if reset_today > now:
            return f"today {h24}"
        else:
            tomorrow = now + datetime.timedelta(days=1)
            return f"{tomorrow.strftime('%a')} {h24}"

    if len(all_resets) >= 1:
        result['session_reset'] = enrich_reset(all_resets[0])
    if len(all_resets) >= 2:
        result['week_all_reset'] = enrich_reset(all_resets[1])

    result['timestamp'] = time.time()
    result['time_str'] = time.strftime('%H:%M:%S')
    return result

def probe():
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ['claude', '--no-chrome', '--dangerously-skip-permissions'],
        stdin=slave, stdout=slave, stderr=slave,
        close_fds=True,
        env={**os.environ, 'TERM': 'dumb', 'COLUMNS': '200', 'LINES': '60'}
    )
    os.close(slave)

    try:
        # Accumulate all output across the session
        all_output = b""

        # Startup + trust prompt
        out1 = read_all(master, 20)
        all_output += out1
        clean1 = clean_ansi(out1)
        if 'trust' in clean1.lower():
            os.write(master, b"\r")
            all_output += read_all(master, 15)

        # Send /status
        os.write(master, b"/status\r")
        time.sleep(3)
        all_output += read_all(master, 3)

        # Navigate: Status -> Config -> Usage (two right arrows)
        os.write(master, b"\x1b[C")
        time.sleep(2)
        all_output += read_all(master, 2)

        os.write(master, b"\x1b[C")
        time.sleep(5)
        all_output += read_all(master, 8)

        # Parse from accumulated output (TUI redraws may split data across reads)
        usage_text = clean_ansi(all_output)

        # Parse
        result = parse_usage(usage_text)
        result['raw'] = usage_text[-500:]

        return result

    finally:
        # Cleanup
        try:
            os.write(master, b"\x1b")
            time.sleep(0.3)
            os.write(master, b"/exit\r")
            time.sleep(1)
        except:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except:
            proc.kill()
        try:
            os.close(master)
        except:
            pass

def main():
    # Simple lock to prevent concurrent probes
    if os.path.exists(LOCK_FILE):
        lock_age = time.time() - os.path.getmtime(LOCK_FILE)
        if lock_age < 120:  # lock younger than 2 min, skip
            print("Another probe is running, skipping", file=sys.stderr)
            return
        os.unlink(LOCK_FILE)

    try:
        with open(LOCK_FILE, 'w') as f:
            f.write(str(os.getpid()))

        result = probe()

        with open(CACHE_FILE, 'w') as f:
            json.dump(result, f, indent=2)

        print(json.dumps(result, indent=2))

    finally:
        try:
            os.unlink(LOCK_FILE)
        except:
            pass

if __name__ == '__main__':
    main()
