# Suspend mode: keep s2idle

`mem_sleep_default=deep` is **not** set. s2idle already behaves as well as it can here.

## The battery cannot measure this

The plan was to compare drain between s2idle and deep. That is not possible on this
machine, because **the battery only reports whole percent.**

```
charge_now / charge_full = 52.0000%      exactly an integer
2052000 -> 2014000 = 38000 uAh = exactly 1%
change in charge_now over six minutes: none
```

One percent is 38000 uAh, so any short measurement reads zero.

| Mode | 10 min | 20 min | Time to move one step |
|---|---|---|---|
| s2idle (assume ~1.5%/h) | 0.25% -> 0 steps | 0.5% -> 0-1 steps | about 40 minutes |
| deep (assume ~0.4%/h) | 0.07% -> 0 steps | 0.13% -> 0 steps | about 2.5 hours |

A meaningful battery comparison needs **two to three hours per mode**.

`current_now` is no help either. It sits at exactly `500000 uA` and does not move,
whatever the load.

## What was measured instead: hardware sleep residency

Rather than watching the battery, measure **whether the SoC actually reaches its deep
idle state**. These counters are in microseconds, so **two minutes is enough**.

```
/sys/power/suspend_stats/last_hw_sleep        hardware sleep time of the last suspend
/sys/power/suspend_stats/total_hw_sleep
/sys/kernel/debug/pmc_core/slp_s0_residency_usec
/sys/kernel/debug/pmc_core/substate_residencies
```

`rtcwake -m mem -s 120` suspends and wakes the machine on its own, and the counters
are read either side.

## Result

```
requested suspend:  120.00s
last_hw_sleep:      119.68s
residency:          99.7%
```

The `slp_s0_residency` delta was 119678584 us, exactly matching `last_hw_sleep`, so
the two corroborate each other.

The substate breakdown is more telling still:

```
S0i2.0 :              0
S0i3.0 : 2,663,748,579     every microsecond in the deepest state
```

Zero time in `S0i2` means nothing stalled at an intermediate state, and
`substate_requirements` being empty means nothing blocked entry at all.

## The decision

1. **s2idle is already optimal.** Spending 99.7% of a suspend in the deepest available
   state leaves deep almost nothing to improve on.
2. **It is the platform default** (`[s2idle] deep`). Modern Intel platforms are
   validated for S0ix; S3 often is not validated by the vendor at all.
3. **Both modes resume cleanly.** Touchscreen, WiFi, tablet switch and the daemon all
   come back either way. So deep is not risky, it simply has nothing to offer.

## What this does not measure

It measures **how deeply the machine sleeps, not how many watts it draws**. In
principle a machine could sit in S0i3 the whole time and still use more power than it
would in S3.

Establishing that needs the battery, which needs hours per mode. If overnight drain
ever feels wrong in use, that is the time to do it: an overnight test supplies the
hours naturally.

## Reproducing this

```bash
# before
cat /sys/power/suspend_stats/last_hw_sleep
cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec

sudo rtcwake -m mem -s 120        # suspend, wake after 120s

# after: the closer last_hw_sleep is to 120s, the better
cat /sys/power/suspend_stats/last_hw_sleep
sudo cat /sys/kernel/debug/pmc_core/substate_residencies
```

Over SSH the connection drops during suspend, so launch it with `setsid nohup` and
read the results from a file once the machine is awake.
