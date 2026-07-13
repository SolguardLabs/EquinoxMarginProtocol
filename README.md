# EquinoxMarginProtocol

![banner](./assets/banner.png)

EquinoxMarginProtocol es un protocolo de margin trading con cuentas aisladas,
garantías multiasset, liquidez interna por activo, actualización de intereses y
liquidaciones parciales. El sistema modela mercados con activo base y activo de
cotización, permite abrir posiciones direccionales y mantiene el riesgo separado
por subcuenta para que los operadores puedan aislar estrategias.

## Componentes

- `EquinoxMarginProtocol`: motor principal de cuentas, posiciones, deuda,
  liquidez, liquidación y transferencias internas.
- `EquinoxOracle`: oráculo controlado para publicar precios por activo con
  ventana de frescura configurable.
- `MockERC20`: tokens locales usados por la suite de Hardhat.
- `AccountTypes`, `RiskMath`, `InterestRateModel`, `FixedPoint`: librerías de
  dominio para accounting, riesgo, intereses y precisión.

## Requisitos

- Node.js 22 o superior.
- npm.

## Instalación

```bash
npm install
```

## Comandos

```bash
npm run compile
npm test
npm run lint
npm run ci
```

## Flujos Cubiertos

- Registro de activos y mercados.
- Depósitos de liquidez por proveedores.
- Apertura de posiciones con margen aislado.
- Actualización del índice de deuda.
- Aportación y retirada de margen.
- Cierre de posiciones con PnL.
- Transferencia operativa entre subcuentas del mismo propietario.
- Liquidación parcial cuando la cuenta cae por debajo de mantenimiento.

## Estructura

```text
src/
  EquinoxMarginProtocol.sol
  interfaces/
  libraries/
  mocks/
  oracle/
  token/
tests/
  helpers/
scripts/
.github/
.vscode/
```

## Estado

La suite de tests de Hardhat valida los flujos principales del protocolo sin
servicios externos. Los contratos están pensados para revisión local y ejecución
determinista.
