# Software charge limiting: parked

An attempt to cap charging at 80% in software. **Reconnaissance only; the work is
parked.** Not because it was shown to be impossible, but because one unknown is
expensive enough to stop on.

## What is established

**The firmware has no charge limit.** A full sweep of the BIOS
([bios-findings.md](bios-findings.md)) and upstream's firmware decompilation agree
independently. So there is no option but to work around it.

**The host I2C path is closed.** Nothing answers at `0x2B` on buses 0 through 5.
Linux has no PD stack here at all: no `/sys/class/typec`, and neither tcpm nor tcpci
is loaded. PD negotiation belongs entirely to the EC.

**The only route is the EC's I2EC bridge**, which upstream mapped by decompiling the
firmware:

```
EC SMBus controller:  I2EC 0x1C00 (channel A)
ANX7447:              I2C 0x37 (PD policy) + 0x2B (TCPCI)
                      the only peripheral on the EC's SMBus
```

**The principle is already proven on this machine.** A hardware Chargie dongle works
by cutting VBUS, so "cutting VBUS stops charging" is established fact. The open
question is only whether software can reach that cut.

## A useful by-product: the charger temperature sensor is real

`minibook_charger` (IT5570E ADC channel 0) was measured and **does reflect the
charging circuit**. Upstream only described it as "probably the charger IC".

```
discharging (no AC):            23C
charging (1.9A x 7.85V, ~15W):  34 -> 35 -> 36C
```

That makes it an independent indicator of whether charging is happening. Battery
percentage reacts slowly; this temperature tracks the circuit directly. It is one of
the reasons `minibook_ec` earns its place.

## Why it is parked: one decisive unknown

Of four obstacles, three are engineering cost or unverified risk. The fourth is a
different kind of thing.

| Obstacle | Nature |
|---|---|
| No userspace I2EC access | Engineering cost. Reachable by extending the kernel module, or by driving the PNPCFG ports directly |
| **The SMBus controller's register layout is unknown** | **A genuine unknown.** Only the base at `0x1C00` is known; the control, status and data register layout inside it is not, and there is no IT5570E datasheet |
| Racing the EC | Unverified. The EC won on fan PWM, but whether it also wins on PD was never tested |
| Only works while the OS is running | A limit of the approach itself |

The second is the bottleneck. Without it an SMBus transaction cannot even be started.

## A wrong argument, recorded

At one point the justification for parking this was that "the author who decompiled
the firmware concluded it is not implemented". **That is a bad argument.** Two
separate claims were being conflated:

- The firmware has no charge limiting *feature* — true
- Therefore VBUS cannot be cut by driving TCPCI directly — **does not follow**

This approach does not ask the firmware for anything; it goes around it.

## If it were picked up again

Cheapest first. All of this is read-only, so none of it is risky.

1. Add a **read-only I2EC debug interface** to `minibook_ec` temporarily.
   `minibook_ec_i2ec_read` already exists, so this is just exposing it through debugfs.
2. **Dump the region around `0x1C00` while charging and while not**, then compare.
   Registers that change are the status and control candidates.
3. Only once the shape is clear, decide whether a write interface is worth building.
   The TCPCI commands themselves (the DisableSinkVbus family) are a public standard
   and documented.

## The alternative

A hardware Chargie dongle does the same job **regardless of what the OS is doing**. It
keeps working while the machine is asleep or off, which makes it strictly better than
any software approach here.
