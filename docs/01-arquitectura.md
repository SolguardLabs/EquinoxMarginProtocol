# Arquitectura del protocolo

EquinoxMarginProtocol organiza activos, mercados y subcuentas alrededor de un ledger único. Las rutas de escritura acumulan primero el pool implicado, consultan precios, aplican la transición y vuelven a evaluar salud. Las vistas agregadas no modifican estado.

## Mapa de componentes

```mermaid
flowchart TB
    subgraph EDGE["Acceso"]
        TR["Trader"]
        LP["Liquidity provider"]
        KP["Keeper"]
    end
    subgraph CORE["Contratos de dominio"]
        MP["EquinoxMarginProtocol"]
        OR["EquinoxOracle"]
        SQ["SettlementQueue"]
        LN["EquinoxLens"]
    end
    subgraph MATH["Bibliotecas"]
        FP["FixedPoint"]
        RM["RiskMath"]
        IR["InterestRateModel"]
        AT["AccountTypes"]
    end
    TR --> MP
    LP --> MP
    KP --> MP
    OR --> MP
    SQ --> MP
    MP --> FP
    MP --> RM
    MP --> IR
    MP --> AT
    MP --> LN
```

| Dominio   | Estado principal                          | Clave                  |
| --------- | ----------------------------------------- | ---------------------- |
| Activo    | token, decimales, factores, flags         | `assetId`              |
| Mercado   | base, quote, leverage, maintenance        | `marketId`             |
| Pool      | cash, shares, principal, índice, reservas | `assetId`              |
| Subcuenta | colateral, deudas, posiciones, nonce      | owner + `subAccountId` |
| Oracle    | precio, timestamp, secuencia              | `assetId`              |

## Ruta de escritura

```mermaid
sequenceDiagram
    participant U as Caller
    participant P as Protocol
    participant I as Interest model
    participant O as Oracle
    participant S as Storage
    U->>P: command + identifiers
    P->>P: authorization + pause checks
    P->>I: accrue quote asset
    P->>O: read current prices
    P->>S: apply accounting transition
    P->>P: compute account snapshot
    alt health accepted
        P-->>U: receipt + events
    else health rejected
        P-->>U: revert entire transaction
    end
```

La atomicidad de EVM impide persistir una transición que termine en revert. Los servicios deben esperar confirmations antes de derivar decisiones posteriores.

## Dependencias de estado

```mermaid
flowchart LR
    AC["Asset config"] --> VAL["Token value"]
    OR["Oracle price"] --> VAL
    PO["Pool index"] --> DEBT["Current debt"]
    AD["Account checkpoint"] --> DEBT
    MC["Market config"] --> REQ["Margin requirements"]
    POS["Position"] --> PNL["Unrealized PnL"]
    VAL --> SNAP["Account snapshot"]
    DEBT --> SNAP
    REQ --> SNAP
    PNL --> SNAP
```

## Principios

- unidades de token se convierten a WAD solo al valorar;
- los arrays de claves permiten enumerar mappings sin duplicados;
- cada pool mantiene su propio reloj e índice;
- el oracle no se sustituye sin una operación administrativa explícita;
- lens y stress engines son de solo lectura respecto al ledger transaccional.
