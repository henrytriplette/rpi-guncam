# rpi-guncam

## Info
- Raspberry Pi camera apps doc: <https://www.raspberrypi.com/documentation/computers/camera_software.html#rpicam-apps>

## Service Changes
Update `/etc/systemd/system/motioneye.service` so motionEye runs via `libcamerify`:

```ini
# Before
ExecStart=/usr/local/bin/meyectl startserver -c /etc/motioneye/motioneye.conf

# After
ExecStart=/usr/bin/libcamerify /usr/local/bin/meyectl startserver -c /etc/motioneye/motioneye.conf
```

Run `sudo systemctl daemon-reload` and `sudo systemctl restart motioneye` after editing the unit.
