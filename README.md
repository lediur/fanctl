# fanctl
Automatic PID fan control for remote IPMI on Debian with Supermicro X9DRi-LN4F+

## Why

For automatically monitoring the two-zone CPU/Peripheral fan controller on a Supermicro X9DRi-LN4F using remote IPMI. Works well from a VM running on this host.

## How

In my setup, the peripheral zone controls a 140mm fan wall mounted in front of the hotswap drive bays of an SC836 3u 16-bay chassis. The CPU zone controls the CPU fans, rear case fans, and a 120mm fan mounted on the rear of the chassis behind the HBA cards to pull air through their heatsinks.

### To deploy

- clone this repo into somewhere reasonable (I used `/opt/fanctl`)
- (optional) set up a .env file to override tuning parameters and logging so you don't have to edit the scripts to do so. read the scripts for tunable params
- `sudo ln -s /opt/fanctl/spinpid2z.service /etc/systemd/system/spinpid2z.service`
- `sudo systemctl enable spinpid2z`
- `sudo systemctl start spinpid2z`

## Equipment

- **Front fan wall**: [Noctua NF-A14 IndustrialPPC-3000 PWM](https://noctua.at/en/nf-a14-industrialppc-3000-pwm) x 3, arranged three wide to blow directly into the drive bays, with a PWM splitter wire running through the front IO panel into the chassis.
- **Rear PCI-e fan**: [Noctua NF-F12 IndustrialPPC-3000 PWM](https://noctua.at/en/nf-f12-industrialppc-3000-pwm) x 1, snug fit in the expansion card area on the rear exterior of the chassis, with the cable running through a perforated expansion slot shield into the chassis.
- **Interior fan wall**: [Noctua NF-A8 PWM](https://noctua.at/en/products/fan/nf-a8-pwm) x 3
- **Rear chassis fans**: [Noctua NF-A8 PWM](https://noctua.at/en/products/fan/nf-a8-pwm) x 2
- **CPU coolers**: [Noctua NH-D9DX i4 3U](https://noctua.at/en/nh-d9dx-i4-3u) x 2. Since the SC836 is a 3U server, decided to play it safe and get a cooler explicitly rated for 3U chassis compatibility.
- All 16 bays populated

## Results

### Temperatures
At idle, with a 24℃ ambient temperature, this setup keeps average drive temperatures around the temperature set point (37C as of writing) with ~40-60% duty cycle with average workloads.

### Noise levels
According to the NIOSH SLM app on my phone, the ambient noise level of my apartment is ~34 dB(A). When measured 3 feet from the server cabinet, at the entry to my closet, I measured these figures using `spintest`:

|Combined duty cycle|Noise (in dB(A))|
|---|---|
|100%|56|
|90%|55|
|80%|53|
|70%|49|
|60%|45.7|
|50%|42.6|
|40%|38|
|30%|34.5|

Since the cabinet is in a closet with an open doorway, the noise is only audible in the adjacent room if the duty cycle is above 60%, or above 40% when standing in front of it.

## Inspirations

- Largely based on https://www.truenas.com/community/threads/fan-scripts-for-supermicro-boards-using-pid-logic.51054/page-13#post-551335, with modifications:
  - made it work under Debian (original was intended for FreeBSD)
  - portability with .env file
  - remote IPMI
  - service for systemctl
- https://www.youtube.com/embed/0UjyL6ZiMkI
