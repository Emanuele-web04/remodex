# Public Repo and Self-Hosting

This file explains what the public Remodex repository is for, what it includes, and what it does not include.

If you cloned Remodex from GitHub, the intended path is local-first usage or self-hosting on infrastructure you control.

## What the Public Repo Includes

The public repository includes:

- the bridge that runs on your Mac
- the iOS app source code
- the public relay code
- local pairing and self-hosting documentation

The public repository is meant to be usable without any private hosted dependency baked into the source tree.

## What the Public Repo Does Not Include

The public repository does not include:

- a private production relay URL
- private App Store build defaults
- private npm publish-time defaults
- private notification credentials
- private deployment secrets

If you are running from source, assume you must provide your own relay setup.

## The Self-Hosting Path

If you use the public repo, you should expect one of these flows:

1. Local LAN pairing on your own machine with `./run-local-remodex.sh`
2. A self-hosted relay on your own VPS, passed in through `REMODEX_RELAY`

That means:

- Codex still runs on your Mac
- git commands still run on your Mac
- the iPhone is still a paired remote client
- the relay is only the transport layer

For most GitHub users, the easiest first step is:

```sh
git clone https://github.com/Emanuele-web04/remodex.git
cd remodex
./run-local-remodex.sh
```

For the full public setup guide, read [Docs/self-hosting.md](Docs/self-hosting.md).

## Why the Repo Stays Generic

The public repo stays generic on purpose.

That keeps the self-host path honest:

- people can inspect the transport and pairing code
- people can run Remodex locally
- people can self-host their own relay
- people are not silently tied to someone else's hosted infrastructure

## Official Builds and Published Packages

Official builds or published packages may be configured differently at release time.

For example, an official package may include a pairing endpoint chosen during publishing, while the public source checkout stays empty by default.

That does not change the goal of the public repo:

- GitHub source should stay self-host friendly
- private release configuration should stay out of Git

## What to Keep Private

If you fork or self-host Remodex, keep these things out of the public repo:

- your deployed hostname
- your VPS IP addresses
- any APNs credentials
- any private build overrides
- any publish-time package defaults

Those belong in your own environment, private config, or release pipeline.

## Short Version

If you cloned Remodex from GitHub:

- do not expect a private hosted relay to be built in
- use `./run-local-remodex.sh` for local testing
- use `REMODEX_RELAY` for your own VPS or hosted relay
- treat the public repo as the self-hostable version of the project
