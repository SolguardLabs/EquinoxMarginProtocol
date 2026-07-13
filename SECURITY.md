# Security Policy

## Modelo De Seguridad

EquinoxMarginProtocol asume que los tokens registrados siguen semántica ERC-20
estándar, que el oráculo publica precios frescos y que los mercados se configuran
con parámetros de riesgo conservadores. La liquidez interna se contabiliza por
activo y los usuarios operan mediante subcuentas aisladas.

## Invariantes Esperadas

- La liquidez libre de un activo no puede ser retirada por encima del efectivo
  disponible.
- Cada posición debe mantener margen suficiente frente al requisito inicial o de
  mantenimiento aplicable.
- Las liquidaciones parciales deben reducir exposición, deuda y garantía de forma
  proporcional al importe repagado.
- Los índices de intereses deben avanzar de forma monotónica.
- Los proveedores de liquidez deben recibir shares contra el NAV del pool.
- Los cambios de configuración solo pueden ser ejecutados por el propietario.

## Validaciones Automatizadas

La suite de Hardhat cubre apertura de posiciones, cierre, aportación de margen,
acumulación de intereses, transferencias internas de subcuentas, liquidación
parcial y accounting de liquidez. La integración continua ejecuta formato,
compilación y tests.

## Gestión De Dependencias

Las dependencias se administran con npm y Dependabot revisa semanalmente el
ecosistema npm y GitHub Actions. Las versiones de Solidity se fijan desde
`hardhat.config.ts`.

## Alcance De Revisión

La revisión debe incluir:

- `src/EquinoxMarginProtocol.sol`
- `src/libraries/`
- `src/oracle/`
- `src/token/`
- `tests/`
- configuración de Hardhat y CI.

## Reporte Interno

Un reporte debe incluir descripción del impacto, precondiciones, secuencia de
transacciones, cuentas afectadas, activos afectados, estimación económica,
recomendación de mitigación y pruebas de regresión propuestas.
