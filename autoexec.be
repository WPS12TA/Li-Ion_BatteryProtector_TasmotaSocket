# Set to 0 to disable ChargeGuard without removing it from autoexec.be
# Then restart – script loads but does nothing, socket works normally
var ENABLED = 1

# Version – update this when making changes
var VERSION = "0.2c"

# Device MQTT topic prefix – check your broker for  tele/<this>/LWT
# e.g. if you see  tele/tasmota_4FB388/LWT  set this to  tasmota_4FB388
var MQTT_TOPIC_PREFIX = "tasmota_4FB388"

# ================================================================
#  charge_guard.be  –  Tasmota Berry Script (ESP32)
#  Lithium Battery Overcharge Protection
#  Supports: laptops, e-bikes, and any Li-Ion / LiPo charger
#
#  HOW IT WORKS
#  ────────────
#  Lithium chargers operate in two phases:
#
#    Phase 1 – CC (Constant Current)
#      The charger pushes a fixed current into the battery.
#      Power draw is HIGH and roughly STABLE.
#      e.g. an e-bike charger at 250W, a laptop at 65W.
#
#    Phase 2 – CV (Constant Voltage)
#      Once the battery reaches its target voltage (~4.2V/cell)
#      the charger holds voltage steady and lets current TAPER
#      down naturally as the battery fills.
#      Power draw FALLS steadily toward zero.
#
#    This script watches the socket's live watt reading.
#    It records the highest watt value seen (the "peak").
#    Once the charger has settled (warm-up period), it checks
#    each sample: if power has fallen to or below a set
#    percentage of that peak, the CV taper is detected and
#    the relay is cut — stopping the charge before the cell
#    is stressed by prolonged top-off at 100%.
#
#    An MQTT message is published when the relay is cut so you
#    can log, alert, or automate further actions externally.
#
#  TYPICAL PEAK WATTS (for tuning MIN_PEAK_WATTS)
#  ───────────────────────────────────────────────
#    Small laptop (45W USB-C)        ~40–50 W
#    Large laptop (140W USB-C)       ~90–140 W
#    E-bike 36V charger (2A)         ~75 W
#    E-bike 48V charger (5A)         ~245 W
#    E-bike 72V fast charger         ~400–700 W
#
#  REQUIREMENTS
#  ────────────
#    • Tasmota ESP32 build with Berry scripting enabled
#    • A power-monitoring socket with an energy sensor chip
#      (BL0937, HLW8012, CSE7766, PZEM-004T, etc.)
#    • MQTT broker configured in Tasmota (if using MQTT alerts)
#    • Save as  autoexec.be  to run automatically on boot,
#      or load manually via Berry console:  load('charge_guard.be')
#
# ================================================================


# ════════════════════════════════════════════════════════════════
#  USER CONFIGURATION  –  edit this section only
# ════════════════════════════════════════════════════════════════

# Which relay controls the socket output.
# Almost always 1 for a single-socket smart plug.
var RELAY_IDX = 1

# How often (in seconds) to read the power sensor.
# 10 s is a good balance – frequent enough to catch the taper
# without hammering the sensor. Don't go below 5 s.
var SAMPLE_INTERVAL_S = 5

# How many samples to collect before acting.
# During warm-up we only record the peak – we never cut the relay.
# This lets the charger settle into its CC phase before we start
# watching for a taper.
# Default: 6 samples × 10 s = 60 seconds warm-up.
# For e-bikes with a slow ramp-up, increase to 12 (= 2 minutes).
var WARMUP_SAMPLES = 12

# The taper detection threshold, expressed as a percentage of
# the peak watts seen during this charge session.
#
# The relay is cut when:
#   current_watts  <=  (peak_watts × TAPER_THRESHOLD_PCT / 100)
#
# Example: peak = 200 W (e-bike), threshold = 40 %
#   → relay cuts when power falls to 80 W or below.
#
# Tuning guide:
#   HIGHER value (e.g. 60) → cuts EARLIER in the taper curve
#                             battery ends up at ~75–80% charge
#                             maximum longevity, less range
#
#   LOWER value  (e.g. 20) → cuts LATER in the taper curve
#                             battery ends up at ~90–95% charge
#                             more range, slightly more cell stress
#
#   40% is a good default that lands around 80–85% charge,
#   which is the widely recommended sweet spot for Li longevity.
#
# Device-specific suggestions:
#   Daily-use laptop (plugged in all day)  → 50–60 %  (prioritise longevity)
#   E-bike (need range tomorrow)           → 30–40 %  (balance range/health)
#   E-bike (long trip, need full range)    → skip this script, charge normally
var TAPER_THRESHOLD_PCT = 75

# Minimum peak watts required before taper detection is armed.
# Prevents false triggers when the socket is idle or powering
# something tiny (a phone trickle-charge, a lamp, etc.).
# Set this to roughly HALF the expected CC-phase wattage of your
# smallest charger.
# Examples:
#   45 W laptop charger  → set 20
#   75 W e-bike charger  → set 35
#   250 W e-bike charger → set 100
var MIN_PEAK_WATTS = 20.0

# After cutting the relay, wait this many minutes before the
# script will respond to the relay being switched back on.
# Prevents the relay being manually re-enabled and immediately
# cut again before you have a chance to unplug the charger.
# Does NOT prevent you manually overriding via the Tasmota UI –
# it just stops the script from cutting it again straight away.
var COOLDOWN_MINUTES = 60

# ── MQTT settings ──────────────────────────────────────────────

# Set to true to publish MQTT messages on state changes.
# Requires MQTT to be configured in Tasmota (Configuration → MQTT).
var MQTT_ENABLE = true

# The suffix appended after the device topic.
# Full published topic will be:  tele/<device>/CHARGER
var MQTT_TOPIC = "CHARGER"


# ════════════════════════════════════════════════════════════════
#  INTERNAL STATE  –  do not edit below this line
# ════════════════════════════════════════════════════════════════

var _peak_w          = 0.0   # Highest watt reading seen this session
var _sample_n        = 0     # Number of samples taken this session
var _active          = false # True while a charge session is in progress
var _cooldown_ts     = 0     # millis() value when cooldown expires (0 = none)
var _session_start_ts = 0   # millis() when relay came ON – used to ensure
                             # at least one full sample interval elapses
                             # before the first reading is taken, regardless
                             # of when in the tick cycle the relay was enabled
var _energy_ws       = 0.0  # Accumulated energy this session in watt-seconds
                             # Converted to Wh at cut:  Wh = _energy_ws / 3600
var _timer           = nil   # Handle to the repeating timer


# ════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ════════════════════════════════════════════════════════════════

# watts()
# Reads the current active power from the energy monitoring chip.
# Returns 0.0 if the sensor is unavailable or not yet ready.
# active_power can be a plain number (single phase) or a list
# (multi-phase clamp meters) – we always use phase 0.
def watts()
  var e = energy.read()               # Ask the energy driver for a snapshot
  if e == nil return 0.0 end          # Sensor not ready – return safe zero
  var p = e.find('active_power')      # Look up the active power key
  if p == nil return 0.0 end          # Key missing – return safe zero
  if type(p) == 'list'
    return real(p[0])                 # Multi-phase: use first phase only
  end
  return real(p)                      # Single-phase: use value directly
end

# relay_off()
# Sends the Tasmota command to turn the relay OFF (cuts socket power).
def relay_off()
  tasmota.cmd('Power' + str(RELAY_IDX) + ' Off')
end

# relay_state()
# Returns true if the relay is currently ON, false if OFF.
# Uses tasmota.get_power() which returns a simple boolean list
# and never returns nil — far safer than parsing cmd() output.
# The list is 0-indexed; RELAY_IDX is 1-indexed, so subtract 1.
def relay_state()
  var pwr = tasmota.get_power()       # e.g. [true] or [true, false]
  if pwr == nil || size(pwr) < RELAY_IDX
    return false                      # Can't read state – assume off
  end
  return pwr[RELAY_IDX - 1]
end

# log(msg)
# Writes a prefixed line to the Tasmota console log at level 2
# (INFO). Visible in the web UI console and serial monitor.
def log(msg)
  tasmota.log('ChGd: ' + msg, 2)
end

# timestamp()
# Returns the current local time as a readable string: "2026-06-27 14:23:05"
# tasmota.rtc() returns a map with keys: utc, local, timezone, restart
# 'local' is a Unix timestamp (seconds since 1970) adjusted for timezone.
# We break it into date/time components using tasmota.time_dump() which
# returns a map: year, month, day, hour, min, sec, weekday.
def timestamp()
  var t = tasmota.rtc()
  if t == nil  return '(no time)'  end
  var local = t.find('local')
  if local == nil  return '(no time)'  end
  var d = tasmota.time_dump(local)    # Break Unix timestamp into components
  # Zero-pad month, day, hour, min, sec to always get fixed-width strings
  var mo  = d['month']  < 10 ? '0' + str(d['month'])  : str(d['month'])
  var day = d['day']    < 10 ? '0' + str(d['day'])    : str(d['day'])
  var hr  = d['hour']   < 10 ? '0' + str(d['hour'])   : str(d['hour'])
  var mn  = d['min']    < 10 ? '0' + str(d['min'])    : str(d['min'])
  var sc  = d['sec']    < 10 ? '0' + str(d['sec'])    : str(d['sec'])
  return str(d['year']) + '-' + mo + '-' + day + ' ' + hr + ':' + mn + ':' + sc
end

# notify(msg)
# Logs a message to the Tasmota console AND publishes it as a plain
# text string to MQTT, prefixed with the current local timestamp. e.g.:
#   "2026-06-27 14:23:05 ChargeGuard: Charge session started"
#
# retained = true so the broker always holds the LAST state message.
# Any new subscriber (MQTT Explorer, Home Assistant, Node-RED) will
# immediately see the most recent status without waiting for an event.
#
# The full topic is built from MQTT_TOPIC_PREFIX + MQTT_TOPIC (see config).
def notify(msg)
  log(msg)                            # Always write to Tasmota console
  if !MQTT_ENABLE return end          # MQTT disabled in config – skip

  # Build plain text payload: timestamp + prefix + message
  var full = timestamp() + ' ChargeGuard: ' + msg

  # Build the full topic using the auto-resolved device prefix
  var topic = 'tele/' + MQTT_TOPIC_PREFIX + '/' + MQTT_TOPIC

  # Publish with retained = true so broker holds latest status for new subscribers
  tasmota.publish(topic, full, true)
end

# _reset_session()
# Clears all per-session state ready for the next charge cycle.
def _reset_session()
  _active            = false
  _peak_w            = 0.0
  _sample_n          = 0
  _session_start_ts  = 0
  _energy_ws         = 0.0  # Reset accumulated energy for next session
end


# ════════════════════════════════════════════════════════════════
#  CORE LOGIC
# ════════════════════════════════════════════════════════════════

# on_tick()
# Called every SAMPLE_INTERVAL_S seconds by the recurring timer.
# This is the main state machine.
def on_tick()
  var now = tasmota.millis()          # Current uptime in milliseconds

  # ── 1. If the relay is off, there is nothing to monitor ──────
  # The relay might have been turned off manually by the user,
  # by another rule, or by a previous cut from this script.
  # Reset session state so we start fresh when it comes back on.
  if !relay_state()
    if _active
      # Relay was switched off manually (button press or external command)
      # while a session was running. Report energy delivered so far
      # before clearing session state – useful to know how much went
      # in before the manual stop.
      var stopped_wh   = int(_energy_ws / 3600)
      var stopped_mins = int(_sample_n * SAMPLE_INTERVAL_S / 60)
      notify('[V' + VERSION + '] Stopped manually – energy delivered ' + str(stopped_wh) + 'Wh'
             ' over ' + str(stopped_mins) + 'min,'
             ' peak ' + str(int(_peak_w)) + 'W,'
             ' session reset, ready for next charge')
    end
    _reset_session()
    return                            # Nothing more to do until relay is on
  end

  # ── 2. Cooldown gate ─────────────────────────────────────────
  # After cutting the relay we start a cooldown timer. Its purpose
  # is to prevent the script immediately re-cutting if the same
  # charger is still plugged in and the relay is flicked back on.
  #
  # HOWEVER – if the user presses the button during cooldown we
  # treat that as a deliberate override (e.g. swapping to a second
  # battery). The relay being ON at this point means they pressed
  # the button, so we cancel cooldown and start a fresh session.
  if _cooldown_ts > 0
    if now < _cooldown_ts
      # Still in cooldown AND relay is ON → user pressed the button deliberately.
      # Cancel cooldown and fall through to start a fresh session below.
      # This handles swapping to a second battery straight after the first.
      notify('[V' + VERSION + '] Cooldown cancelled – relay enabled, starting fresh session')
      _cooldown_ts = 0                # Clear cooldown, fall through below
    else
      # Cooldown has expired naturally on this tick.
      # Notify so the user knows the socket is armed and ready again.
      # The relay is OFF at this point (script cut it) so we just report
      # readiness – monitoring will start the moment the button is pressed.
      notify('[V' + VERSION + '] Cooldown complete – monitoring armed, enable relay to start next charge')
      _cooldown_ts = 0                # Clear cooldown
      return                          # Relay is off, nothing more to do this tick
    end
  end

  # ── 3. Detect start of a new session ─────────────────────────
  # The relay is ON and we're not in an active session yet.
  # Record the start timestamp so we can enforce a minimum delay
  # before the first sample is taken – this ensures the charger
  # has had at least one full sample interval to begin ramping up,
  # regardless of when in the tick cycle the relay was switched on.
  if !_active
    _active            = true
    _peak_w            = 0.0
    _sample_n          = 0
    _session_start_ts  = now          # Record when relay came ON
    # Announce session start – first message the broker sees for this cycle
    notify('[V' + VERSION + '] Charge session started – first sample in ' +
           str(SAMPLE_INTERVAL_S) + 's, warm-up ' +
           str(WARMUP_SAMPLES * SAMPLE_INTERVAL_S) + 's total')
    return                            # Skip this tick – wait one full interval
  end

  # ── 4. Read power ────────────────────────────────────────────
  # Enforce minimum delay from session start before first sample.
  # This guards against a relay being switched on mid-tick where
  # the charger hasn't had time to begin drawing current yet.
  if (now - _session_start_ts) < (SAMPLE_INTERVAL_S * 1000)
    return                            # Too soon – wait for full interval
  end

  var w = int(watts())                # Live watts, rounded to nearest integer
  _sample_n += 1                      # Increment sample counter
  _energy_ws += w * SAMPLE_INTERVAL_S # Accumulate watt-seconds for this sample

  # ── 5. Warm-up phase ─────────────────────────────────────────
  # For the first WARMUP_SAMPLES samples we just track the peak
  # and do nothing else. This lets the charger ramp up and
  # stabilise in its CC phase before we start watching for a taper.
  if _sample_n <= WARMUP_SAMPLES
    if w > _peak_w  _peak_w = w  end  # Keep updating peak during warm-up
    # On the last warm-up sample, check MIN_PEAK_WATTS BEFORE reporting.
    # If no meaningful load was seen, abort cleanly rather than arming
    # taper detection with a 0W peak which would trip immediately.
    if _sample_n == WARMUP_SAMPLES
      if _peak_w < MIN_PEAK_WATTS
        notify('[V' + VERSION + '] Warm-up complete but peak (' + str(_peak_w) + 'W) is below minimum (' +
               str(MIN_PEAK_WATTS) + 'W) – no charger detected, resetting session. ' +
               'Plug in charger and press button to try again.')
        relay_off()                   # Cut relay – nothing useful is connected
        _reset_session()
        return
      end
      # Peak is valid – report threshold and arm taper detection
      var cut_at = int(_peak_w * TAPER_THRESHOLD_PCT / 100.0)
      notify('[V' + VERSION + '] Warm-up complete – peak ' + str(int(_peak_w)) + 'W,'
             ' taper detection armed, will cut at <= ' + str(cut_at) + 'W'
             ' (' + str(TAPER_THRESHOLD_PCT) + '% of peak)')
    end
    return                            # Don't check taper yet
  end

  # ── 6. Update peak after warm-up ─────────────────────────────
  # The peak can still rise slightly after warm-up (e.g. a charger
  # that ramps slowly). We keep updating it so the threshold
  # is always relative to the true maximum seen.
  if w > _peak_w  _peak_w = w  end

  # ── 7. Sanity check – is this a real charger? ────────────────
  # Belt-and-braces check in case power drops to zero after warm-up
  # (e.g. charger unplugged mid-session without button press).
  if _peak_w < MIN_PEAK_WATTS
    notify('[V' + VERSION + '] Power lost mid-session (peak now ' + str(_peak_w) + 'W) – resetting')
    _reset_session()
    return
  end

  # ── 8. Taper detection ───────────────────────────────────────
  # Calculate what percentage of the peak the current reading is.
  # Use real division throughout to avoid integer truncation errors.
  # Both w and _peak_w are cast to real explicitly to ensure Berry
  # does not accidentally perform integer division (e.g. 96/97 = 0).
  #   pct = 100  → same as peak (full CC power)
  #   pct = 50   → half the peak (well into CV taper)
  #   pct = 10   → nearly finished
  var pct = (real(w) / real(_peak_w)) * 100.0
  var pct_int = int(pct + 0.5)        # Round to nearest integer for display

  # Single merged console log line – sample number, energy, taper %, watts
  log('#' + str(_sample_n) + ', ' +
      str(int(_energy_ws / 3600)) + 'Wh, ' +
      str(pct_int) + '%, ' +
      str(int(w)) + 'W now, ' + str(int(_peak_w)) + 'W peak, ' +
      '(cut@' + str(TAPER_THRESHOLD_PCT) + '%)')

  # ── 9. Cut if threshold reached ──────────────────────────────
  # Compare real pct against real threshold to avoid type mismatch
  if pct <= real(TAPER_THRESHOLD_PCT)
    relay_off()                       # Cut socket power immediately

    # Publish the cut event – energy first, then supporting detail
    var session_wh   = int(_energy_ws / 3600)
    var session_mins = int(_sample_n * SAMPLE_INTERVAL_S / 60)

    # Main charge complete message with energy prominent at the start
    notify('[V' + VERSION + '] CHARGE COMPLETE: ' + str(session_wh) + 'Wh delivered,'
           ' session ' + str(session_mins) + 'min.'
           ' Peak ' + str(int(_peak_w)) + 'W,'
           ' final ' + str(int(w)) + 'W (' + str(pct_int) + '% of peak),'
           ' threshold ' + str(TAPER_THRESHOLD_PCT) + '%,'
           ' cooldown ' + str(COOLDOWN_MINUTES) + 'min.')

    # Short retained message on separate topic for dashboard display.
    # Always shows the last completed charge energy at a glance.
    var wh_topic = 'tele/' + MQTT_TOPIC_PREFIX + '/' + MQTT_TOPIC + '_WH'
    var wh_msg   = timestamp() + ' ChGd: ' + str(session_wh) + 'Wh delivered, session ' + str(session_mins) + 'min'
    tasmota.publish(wh_topic, wh_msg, true)  # true = retained
    log('MQTT → ' + wh_topic + ' ' + wh_msg)

    _cooldown_ts = now + (COOLDOWN_MINUTES * 60 * 1000)

    _reset_session()                  # Clear session state for next cycle
  end
end


# ════════════════════════════════════════════════════════════════
#  TIMER LOOP
# ════════════════════════════════════════════════════════════════

# on_tick_loop()
# Called by the Tasmota timer every SAMPLE_INTERVAL_S seconds.
# Re-arms itself at the START of each tick so that time taken
# by on_tick() does not accumulate as drift. This keeps the
# interval consistent regardless of how long the tick takes.
# Tasmota's set_timer is one-shot only, so we must re-arm
# manually each time – this is the standard Berry pattern.
def on_tick_loop()
  tasmota.set_timer(                  # Re-arm FIRST to avoid drift
    SAMPLE_INTERVAL_S * 1000,         # Convert seconds → milliseconds
    /-> on_tick_loop()                # Lambda calls this same function
  )
  on_tick()                           # Then run the main logic
end

# startup_notify()
# Sends the startup MQTT message with version and all active constants.
# Called via tasmota.add_rule on mqtt#Connected so it only fires
# once the broker connection is established – ensuring the message
# is actually delivered when loaded as autoexec.be on boot.
def startup_notify()
  notify('Ver ' + VERSION + ' loaded –'
         ' relay ' + str(RELAY_IDX) + ','
         ' sample every ' + str(SAMPLE_INTERVAL_S) + 's,'
         ' warm-up ' + str(WARMUP_SAMPLES * SAMPLE_INTERVAL_S) + 's'
         ' (' + str(WARMUP_SAMPLES) + ' samples),'
         ' cut at ' + str(TAPER_THRESHOLD_PCT) + '% of peak,'
         ' min peak ' + str(int(MIN_PEAK_WATTS)) + 'W,'
         ' cooldown ' + str(COOLDOWN_MINUTES) + 'min,'
         ' MQTT ' + (MQTT_ENABLE ? 'on ' : 'off') +
         (MQTT_ENABLE ? 'tele/' + MQTT_TOPIC_PREFIX + '/' + MQTT_TOPIC : ''))
end

# start()
# Entry point. Logs the active configuration to console, registers
# the MQTT connected rule so the startup notify fires once the broker
# is ready, then kicks off the first timer tick.
# Called once at the bottom of this file.
def start()
  # Check enable switch – if 0, log to console and exit immediately.
  # No timers started, no MQTT, socket operates as a normal dumb plug.
  if ENABLED == 0
    log('ChGd Ver ' + VERSION + ' DISABLED – set ENABLED=1 and restart to activate')
    return
  end
  log('════════════════════════════════════')
  log('ChGd Ver ' + VERSION + ' loaded')
  log('  Relay index      : ' + str(RELAY_IDX))
  log('  Sample interval  : ' + str(SAMPLE_INTERVAL_S) + ' s')
  log('  Warm-up samples  : ' + str(WARMUP_SAMPLES) +
      ' (' + str(WARMUP_SAMPLES * SAMPLE_INTERVAL_S) + ' s)')
  log('  Taper threshold  : <= ' + str(TAPER_THRESHOLD_PCT) + '% of peak')
  log('  Min peak watts   : ' + str(MIN_PEAK_WATTS) + ' W')
  log('  Cooldown         : ' + str(COOLDOWN_MINUTES) + ' min')
  log('  MQTT             : ' + (MQTT_ENABLE ? 'enabled' : 'disabled'))
  log('════════════════════════════════════')

  # Register rule to fire startup_notify once MQTT broker connects.
  # This ensures the version message always arrives on the broker
  # regardless of boot timing.
  tasmota.add_rule('Mqtt#Connected', /-> startup_notify())

  tasmota.set_timer(                  # Fire first tick after one interval
    SAMPLE_INTERVAL_S * 1000,
    /-> on_tick_loop()
  )
end

# ── Run ──────────────────────────────────────────────────────────
start()
