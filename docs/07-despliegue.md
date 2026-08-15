# Despliegue y promoción

La entrega estable conserva el mismo commit desde la revisión hasta el release. El pipeline compila con lockfile, ejecuta pruebas y typecheck, valida tamaño EIP-170, documentación, banner y hashes de compatibilidad.

## Cadena de promoción

```mermaid
flowchart LR
    F["Feature branch"] --> PR["Pull request"]
    PR --> CI["CI Ubuntu + Windows"]
    CI --> M["main"]
    M --> P["production"]
    P --> T["Annotated v1.0.0"]
    T --> R["Production 1.0.0 release"]
    M -. exact SHA .-> P
    P -. peeled commit .-> T
```

## Secuencia de contratos

```mermaid
sequenceDiagram
    participant G as Governance
    participant O as Oracle
    participant P as Margin protocol
    participant S as Stress engine
    participant V as Verifier
    G->>O: deploy + configure publishers
    G->>P: deploy with oracle
    G->>P: register assets
    G->>P: configure interest
    G->>P: register markets
    G->>S: deploy stateless engine
    V->>O: verify bytecode + config
    V->>P: verify bytecode + state
    V->>S: canonical stress vectors
```

Las direcciones y parámetros se guardan en un manifiesto por red. No se reutilizan direcciones de mocks ni claves de desarrollo.

## Gates de entrega

```mermaid
flowchart TD
    LOCK["npm ci"] --> FMT["Prettier"]
    FMT --> CMP["Hardhat compile"]
    CMP --> TS["TypeScript strict"]
    TS --> TEST["16+ tests"]
    TEST --> SIZE["EIP-170 sizes"]
    SIZE --> AUD["Production dependency audit"]
    AUD --> REL["Release verifier"]
    REL --> HASH["Protected source hashes"]
```

```bash
npm ci
npm run ci
```

## Verificación post-despliegue

- owner y oracle coinciden con el manifiesto;
- assets conservan token, decimales y factores aprobados;
- curvas y reserve factors son exactos;
- mercados parten con estado y leverage esperados;
- bytecode coincide con el artefacto del tag;
- una lectura de stress canónica devuelve el vector aprobado;
- eventos de inicialización quedan indexados y finalizados.

## Rollback

Los contratos no se actualizan implícitamente. Un rollback operativo usa pausa, `reduceOnly`, restauración de servicios o despliegue/migración gobernada. Nunca se cambia oracle o ownership para simular un rollback sin un plan de estado, balances, approvals y comunicación verificable.

La evidencia de entrega incluye PR, SHAs, Actions de `main`, `production`, tag y release, objeto tag anotado, hashes de contratos y banner, resultados de pruebas y manifiesto de red.
