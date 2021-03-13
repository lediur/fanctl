# fanctl
Automatic fan control for remote IPMI on Debian with Supermicro X9DRi-LN4F+

## Why

For automatically monitoring the two-zone CPU/Peripheral fan controller on a Supermicro X9DRi-LN4F using remote IPMI. Works well from a VM running on this host.

## How

In my setup, the peripheral zone controls a 140mm fan wall mounted in front of the hotswap drive bays of an SC836 3u 16-bay chassis. The CPU zone controls the CPU fans, rear case fans, and a 120mm fan mounted on the rear of the chassis behind the HBA cards to pull air through their heatsinks.

## Equipment

- **Front fan wall**: [Noctua NF-A14 IndustrialPPC-3000 PWM](https://noctua.at/en/nf-a14-industrialppc-3000-pwm) x 3, arranged three wide to blow directly into the drive bays, with a PWM splitter wire running through the front IO panel into the chassis.
- **Rear PCI-e fan**: [Noctua NF-F12 IndustrialPPC-3000 PWM](https://noctua.at/en/nf-f12-industrialppc-3000-pwm) x 1, snug fit in the expansion card area on the rear exterior of the chassis, with the cable running through a perforated expansion slot shield into the chassis.
- **Interior fan wall**: [Noctua NF-A8 PWM](https://noctua.at/en/products/fan/nf-a8-pwm) x 3
- **Rear chassis fans**: [Noctua NF-A8 PWM](https://noctua.at/en/products/fan/nf-a8-pwm) x 2
- **CPU coolers**: [Noctua NH-D9DX i4 3U](https://noctua.at/en/nh-d9dx-i4-3u) x 2. Since the SC836 is a 3U server, decided to play it safe and get a cooler explicitly rated for 3U chassis compatibility.

## Inspirations

- https://www.truenas.com/community/threads/fan-scripts-for-supermicro-boards-using-pid-logic.51054/page-13#post-551335
- https://www.youtube.com/embed/0UjyL6ZiMkI
