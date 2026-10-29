# Agents

Foundry Solidity repo. CI is `.github/workflows/test.yml`: `FOUNDRY_PROFILE=ci`, Foundry stable from `foundry-rs/foundry-toolchain@v1`. `foundry.toml` has no `[profile.ci]`; Forge warns and uses `[profile.default]`.

## Install

```bash
curl -L https://foundry.paradigm.xyz | bash
~/.foundry/bin/foundryup
git submodule update --init --recursive
yarn install --frozen-lockfile
```

Cloud agents run those steps from `.cursor/environment.json`, then symlink `forge`, `cast`, `anvil`, and `chisel` into `/usr/local/bin`. Non-interactive login shells do not load `~/.bashrc`, so the Foundry PATH line there is not enough.

The default image already has Node.js and Yarn classic (verified Node v22.23.4, Yarn 1.22.22). It does not include Foundry.

## Build, test, format

```bash
forge build --sizes
forge test -vvv
forge fmt --check
```

## Gotchas

- `lib/` is git submodules. `forge build` fails until `git submodule update --init --recursive`.
- The first `forge build` downloads Solidity 0.8.37 (selected from the sources). Build and `forge test` do not need an RPC URL or secrets.
- `forge fmt --check` fails on Foundry 1.8.6 (stable on 2026-10-29). The formatter wants different wrapping than the committed sources. Leave application code unchanged unless asked to reformat.
- `forge build` exits 0 with compiler and lint warnings.
- Deploy and upgrade scripts are outside CI. They read a gitignored `.env` (`env.example`, `script/README.md`) and take the RPC URL as `--rpc-url`. Do not commit mnemonics or private keys.
- `@openzeppelin/upgrades-core` (Yarn) is for upgrade deploy scripts via Foundry `ffi`. `forge test` does not need it, but install it so those scripts can run.
