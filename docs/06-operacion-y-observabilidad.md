# Operación y observabilidad

La operación combina indexación confirmada, keepers idempotentes, evaluación de riesgo y procedimientos por activo o mercado. Ningún servicio debe depender solo de eventos pendientes de finalización.

## Topología operativa

```mermaid
flowchart TB
    RPC1["Primary RPC"] --> IDX["Finalized indexer"]
    RPC2["Fallback RPC"] --> IDX
    IDX --> DB["Canonical state store"]
    DB --> RISK["Risk evaluator"]
    RISK --> K["Keeper scheduler"]
    K --> TX["Signer / relayer"]
    TX --> CHAIN["Protocol contracts"]
    CHAIN --> IDX
    DB --> OBS["Metrics + alerts"]
```

El signer solo recibe llamadas previamente construidas y permitidas. El scheduler fija chain ID, dirección, nonce, gas y deadline; el signer no decide parámetros económicos.

## Ciclo de keeper

```mermaid
sequenceDiagram
    participant I as Indexer
    participant R as Risk service
    participant K as Keeper
    participant C as Chain
    I->>R: finalized snapshot
    R-->>K: action candidate + policy version
    K->>C: eth_call simulation
    C-->>K: expected deltas
    K->>C: signed transaction
    C-->>I: receipt + events
    I->>R: reconciled state
    R-->>K: close idempotency key
```

La clave de idempotencia combina acción, owner, subcuenta, activo/mercado, bloque de decisión y versión de política. Una transacción reemplazada conserva la misma intención.

## Respuesta a incidentes

```mermaid
stateDiagram-v2
    [*] --> Healthy
    Healthy --> Degraded: RPC, oracle o keeper
    Degraded --> ReduceOnly: riesgo de mercado
    ReduceOnly --> Paused: integridad no confirmada
    Paused --> Recovering: causa contenida
    Recovering --> Healthy: replay + reconciliación
    Degraded --> Healthy: servicio restaurado
```

Runbook mínimo:

1. fijar red, bloque, contrato, activo y mercado;
2. detener nuevas acciones de riesgo en el perímetro afectado;
3. comparar dos RPC y el oracle autorizado;
4. capturar configuración, bytecode, storage relevante y transacciones;
5. reproducir sobre fork del bloque fijado;
6. reconciliar cash, deuda, shares, reservas y cuentas;
7. restaurar límites de forma gradual con observación reforzada.

## Métricas

Mantenga utilización, borrow APR, edad del accrual, cash disponible, retiros previstos, deuda agregada, reservas, health buckets, liquidaciones pendientes, concentración, confianza del oracle y bandas de stress. IDs de cuenta y transacción pertenecen a logs/traces, no a labels de alta cardinalidad.
