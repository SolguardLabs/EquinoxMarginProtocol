# Liquidaciones

La liquidación reduce deuda y posición cuando el equity cae por debajo del mantenimiento. El quote limita repayment por deuda corriente y close factor, calcula colateral con bonus y devuelve el notional que debe cerrarse.

## Elegibilidad

```mermaid
flowchart TD
    A["Account snapshot"] --> E["Weighted collateral + PnL - debt"]
    M["Maintenance requirement"] --> C{"Equity < maintenance"}
    E --> C
    C -->|no| R["Not liquidatable"]
    C -->|sí| Q["Build liquidation quote"]
    Q --> F["Apply close factor"]
    F --> S["Compute seize amount"]
```

La lectura de elegibilidad y la ejecución deben ocurrir con precios vigentes. Un quote off-chain es orientativo; el contrato vuelve a evaluar el estado en la transacción.

## Waterfall

```mermaid
sequenceDiagram
    participant L as Liquidator
    participant P as Protocol
    participant O as Oracle
    participant D as Debt pool
    participant A as Account
    L->>P: liquidate(owner, subaccount, repay)
    P->>O: current prices
    P->>P: quote + eligibility
    L->>P: transfer repay token
    P->>D: reduce debt principal + increase cash
    P->>A: reduce position + seize collateral
    P-->>L: transfer seized token
    P-->>L: Liquidated event
```

```text
repay = min(requested, currentDebt, currentDebt × closeFactor)
repayValue = tokenValue(repay)
seizeValue = repayValue × (1 + liquidationBonus)
closeNotional = openNotional × repay / currentDebt
```

## Estado tras la ejecución

```mermaid
stateDiagram-v2
    [*] --> Eligible
    Eligible --> PartiallyReduced: close factor menor a 100%
    Eligible --> Closed: debt and position cleared
    PartiallyReduced --> Healthy: equity restored
    PartiallyReduced --> Eligible: further reduction required
    Healthy --> [*]
    Closed --> [*]
```

## Política de keeper

- simular con el bloque inmediatamente anterior;
- limitar precio de gas y tamaño de repayment;
- no asumir disponibilidad de colateral sin leer balance;
- registrar quote, tx hash, bloque y deltas finales;
- reintentar por estado, no por texto del revert;
- alertar si varias ejecuciones no restauran salud.
