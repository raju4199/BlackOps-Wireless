# BlackOps Wireless -- Lab Authorization & Scope

This document must be filled out and kept in this repo (locally -- do not
need to publish real details publicly) **before** running any tool in
`lab.sh`. It exists so there is always a clear, written record of what is
in scope, and it is the thing `lab.sh` asks you to confirm against every
session.

## 1. Ownership / authorization

- [ ] I own all hardware and networks listed below, **or**
- [ ] I have signed, written authorization from the owner to test the
      networks listed below (attach or reference the authorization doc).

Authorized by: ______________________________
Date range of authorization: _______ to _______

## 2. Scope -- networks/devices this lab is allowed to touch

| SSID | BSSID (if known) | Owning device (router model / test AP) | Notes |
|------|-------------------|------------------------------------------|-------|
|      |                   |                                            |       |
|      |                   |                                            |       |

Anything **not** listed in this table is out of scope. Neighboring
networks picked up during scans must not be targeted, associated with,
deauthenticated, or brute-forced -- passive discovery only.

## 3. Environment isolation

- [ ] Test AP/router is physically isolated (own room, low power, or a
      Faraday enclosure) or on a channel/frequency unlikely to overlap
      real neighboring traffic.
- [ ] Test AP does not bridge to any production network or the internet
      in a way that would let an attack pivot outward.
- [ ] Devices used to test (test phone/laptop) are dedicated test
      devices, not daily-driver accounts.

## 4. Tester

Name: ______________________________
Role / reason for testing (learning, CTF prep, auditing own home network,
authorized client engagement, etc.): ______________________________

## 5. Logging

- [ ] I will keep `install.log` and any captured handshakes/PCAPs inside
      this repo's `tools/` or a `captures/` folder that is git-ignored
      (see `.gitignore`), not committed to a public remote.

---

By running `lab.sh`, you'll be asked to type
`I CONFIRM AUTHORIZATION` acknowledging the boxes above are true for this
session. That's a speed bump, not a legal safeguard -- the real
authorization is whatever is written in section 1.
