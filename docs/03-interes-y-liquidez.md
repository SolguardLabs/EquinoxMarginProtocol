# Interés y liquidez

Cada activo prestable mantiene cash, shares, principal agregado, índice de préstamo y reservas. La curva kinked ajusta el coste por segundo a la utilización. El accrual es discreto: se materializa cuando una operación toca el pool o un keeper llama explícitamente.

## Curva de utilización

```mermaid
flowchart LR
    C["Pool cash"] --> U["Utilization"]
    D["Current pool debt"] --> U
    U --> K{"u <= kink"}
    K -->|sí| S1["base + slope1 × u/kink"]
    K -->|no| S2["base + slope1 + slope2 × excess"]
    S1 --> R["Rate per second"]
    S2 --> R
    R --> I["Borrow index"]
```

```text
u = debt / (cash + debt)
indexDelta = borrowIndex × ratePerSecond × elapsed
interestAccrued = currentDebt × ratePerSecond × elapsed
reserveAccrued = interestAccrued × reserveFactor
```

## Accrual y checkpoints

```mermaid
sequenceDiagram
    participant C as Caller
    participant P as Protocol
    participant M as InterestRateModel
    participant S as Pool storage
    C->>P: operation(asset)
    P->>S: cash + principal + old index + timestamp
    P->>M: previewAccrual
    M-->>P: rate + new index + reserves
    P->>S: persist index, timestamp, reserve balance
    P-->>C: continue operation
```

El principal agregado del pool se normaliza a WAD en el momento del préstamo. Las deudas de cuenta conservan su checkpoint para convertir principal nominal a deuda corriente.

## Shares de liquidez

```mermaid
flowchart TD
    DEP["Deposit amount"] --> NAV["Pool net assets"]
    NAV --> MINT["Mint shares"]
    MINT --> POS["Provider balance"]
    POS --> PRE["Preview withdrawal"]
    PRE --> CASH{"Cash disponible"}
    CASH -->|sí| BURN["Burn shares + transfer"]
    CASH -->|no| WAIT["Wait for repayment / liquidity"]
```

```text
netAssets = cash + currentPoolDebt - reserveBalance
sharesMinted = deposit × totalShares / netAssetsBefore
withdrawAmount = sharesBurned × netAssets / totalShares
```

La vista económica y la capacidad inmediata son distintas: una share puede representar deuda devengada aunque el cash no permita retirarla en ese bloque.

## Monitoreo recomendado

- utilización y pendiente de la curva por activo;
- edad desde `lastAccrualTime`;
- cash frente a retiros previstos;
- deuda agregada frente a suma de cuentas;
- crecimiento de `reserveBalance`;
- concentración de shares y de borrowers.
