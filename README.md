# Production Automation

A collection of automation I built and ran in production environments over the years. The common thread: I kept finding manual, after-hours, error-prone processes and engineering the pain out of them.

These scripts ran in real environments, on schedules, with real stakes. They've been de-identified for sharing, with the environment-specific values moved to the top and marked clearly so anyone can adapt them.

## What's here

- **[Horizon VDI Monitor](horizon/HorizonMonitoringScript.ps1)** — a low-desktop, error-desktop and connection-server health monitor for a VMware/Omnissa Horizon VDI environment. Built over a weekend after getting a quote for a commercial monitoring product, it ran every 15 minutes and alerted on low desktop pools, error desktops, and unhealthy connection servers. It let me patch pools safely on a schedule and eliminated the need for a third-party solution.

- **[Horizon 3-Phase Patching](horizon/HorizonPatchingJenkins.ps1)** — the companion to the monitor. Driven by Jenkins parameters, it runs the full VDI patch cycle in three phases: snapshot the gold images and push to test, validate, then promote the tested image to production with scheduled maintenance windows. Includes a failsafe that aborts the run if any gold image is powered on, since snapshotting a running parent image corrupts it. This automation handled five gold images across many pools every patch cycle.

- **[IIS Farm Rolling Deployment](IIS/IISFarmDeployment.ps1)** — deploys application code to a load-balanced IIS farm with zero downtime, and without anyone sitting at a desk during the change window. Driven by Jenkins parameters, it updates the front-end and back-end (API) servers one at a time so a healthy server always serves traffic. Backs up and zips current code before each deploy, puts hosts into monitoring maintenance so expected restarts don't alarm, and includes a stubborn-file failsafe that mirrors an empty directory over a locked target when a normal delete fails. It emails the app team from the runner's own address when finished.

## A note on these scripts

Everything here is real work, cleaned up for sharing. Credentials always came from a secret store, never hardcoded. Anything you need to change for your own environment is marked `CHANGE` and lives near the top of each file.
