# Local changes

Based on upstream CodexPlusPlus v1.5.0, with its Git history retained.

- HTTP request body limit: 128 MiB decoded and 256 MiB encoded.
- Regression coverage: compressed requests above the former 32 MiB limit are accepted; requests above 128 MiB are rejected.
- `extras/QuotaBar`: a native macOS menu bar app for CLIProxyAPI account quotas. Five-hour and weekly totals are calculated independently. Incomplete quota data is displayed as unavailable rather than a partial total.

QuotaBar reads the local EasyCLIProxyAPI management key at runtime. No account files, keys, session logs, clipboard history, or machine configuration are distributed in this repository.

## Build QuotaBar

```sh
cd extras/QuotaBar
./build.sh
```

The menu bar total is relative: 100% means one account's full quota. Different subscription plans can have different absolute capacities.
