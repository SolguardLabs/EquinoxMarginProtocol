# Cuentas y margen

Una dirección puede operar varias subcuentas aisladas. Cada una mantiene colateral, deuda y posiciones sin netear automáticamente con otras subcuentas. El aislamiento permite límites y liquidaciones precisos, pero exige identificar siempre owner, subcuenta y activo.

## Composición de la cuenta

```mermaid
flowchart TD
    A["SubAccount"] --> C["Collateral assets"]
    A --> D["Debt assets"]
    A --> P["Position markets"]
    A --> N["Nonce + status"]
    C --> WV["Weighted collateral"]
    D --> DV["Debt value"]
    P --> UP["Unrealized PnL"]
    P --> MR["Initial + maintenance"]
    WV --> H["Health snapshot"]
    DV --> H
    UP --> H
    MR --> H
```

```text
equity = weightedCollateralValue + unrealizedPnl - debtValue
initialRequirement = Σ(openNotional × initialMarginRate)
maintenanceRequirement = Σ(openNotional × maintenanceRate)
healthy = equity >= initialRequirement
liquidatable = equity < maintenanceRequirement
```

## Apertura y cierre

```mermaid
sequenceDiagram
    participant T as Trader
    participant P as Protocol
    participant O as Oracle
    participant L as Pool ledger
    T->>P: openPosition(subaccount, market, notional)
    P->>O: base + quote prices
    P->>L: increase debt / reduce cash
    P->>P: increase position
    P->>P: require healthy
    P-->>T: PositionOpened
    T->>P: closePosition(portion)
    P->>P: realize PnL + settle debt
    P-->>T: PositionClosed
```

El cierre parcial calcula PnL sobre el tamaño reducido y amortiza una fracción proporcional de deuda. Si el margen del mismo activo no cubre el repayment, el resto se toma de la wallet mediante `transferFrom`.

## Traslado entre subcuentas

```mermaid
flowchart LR
    S["Source snapshot"] --> C["Move collateral portion"]
    C --> P["Move position portion"]
    P --> D["Move debt representation"]
    D --> HS{"Source healthy or empty"}
    D --> HT{"Target healthy"}
    HS -->|sí| R["Transfer receipt"]
    HT -->|sí| R
    HS -->|no| X["Revert"]
    HT -->|no| X
```

El porcentaje usa basis points y se aplica de forma coherente a notional, tamaño, colateral y principal. Un integrador debe presentar al usuario las snapshots antes y después, el ID de transferencia y los índices de deuda relevantes.

## Reglas de integración

- no reutilizar `subAccountId` entre tenants;
- mostrar deuda actual, no solo principal;
- estimar salud con el mismo bloque y precios que la transacción;
- exigir allowance suficiente para cierres que consuman wallet;
- invalidar previews cuando cambie el índice, el precio o la configuración.
