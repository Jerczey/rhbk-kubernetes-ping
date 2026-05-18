# rhbk-kubernetes-ping

Laboratorio en **CRC / OpenShift** para desplegar **Red Hat Build of Keycloak (RHBK) 26.4** con PostgreSQL, réplicas en cluster y descubrimiento de nodos vía stacks de caché Infinispan/JGroups.

Incluye dos caminos de despliegue:

| Directorio | Descripción |
|------------|-------------|
| `operador/manifests/` | Operador RHBK + Keycloak CR |
| `no-operador/manifests/` | Deployment manual sin operador |

Comandos de instalación: [`commands`](commands).

---

# Stacks de caché y descubrimiento de nodos (RHBK / Keycloak 26.4)

Este documento resume cómo Keycloak forma clusters entre réplicas, qué stacks existen en la versión 26.4, cuál conviene usar y qué se sabe sobre su retirada.

Referencias oficiales:

- [Configuring distributed caches (RHBK 26.4)](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/server_configuration_guide/caching-)
- [Deprecated features (RHBK 26.4)](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/release_notes/deprecated)
- [Keycloak caching guide](https://www.keycloak.org/server/caching)

---

## Conceptos básicos

| Concepto | Descripción |
|----------|-------------|
| `cache` | Motor de caché. En producción: `ispn` (Infinispan embebido). |
| `cache-stack` | Stack de transporte JGroups: protocolo de red + mecanismo de **descubrimiento** de nodos. |
| Descubrimiento | Cómo cada pod encuentra a los demás para formar un único cluster. |
| Puerto 7800 | Comunicación de datos del cluster (por defecto). |
| Puerto 57800 | Detección de fallos (`FD_SOCK2`, offset +50000 por defecto). |

Sin `cache=ispn` y sin stack adecuado, cada réplica es una isla: las sesiones no se comparten.

---

## Stack recomendado hoy: `jdbc-ping`

Desde **Keycloak 26.0** el valor por defecto es `jdbc-ping` (antes era `udp` en instalaciones genéricas).

| Aspecto | Detalle |
|---------|---------|
| Transporte | TCP |
| Descubrimiento | Tabla en la **misma base de datos** de Keycloak (`JDBC_PING2`) |
| Config extra en K8s | **No** requiere Service headless ni `jgroups.dns.query` |
| Operador RHBK 26.4 | Usa `jdbc-ping` por defecto (ya no configura `kubernetes`) |

**Ventajas**

- Menos piezas en Kubernetes (sin DNS headless obligatorio).
- Misma DB que ya usas para Keycloak.
- Menos errores de configuración (como `dns_query can not be null or empty`).
- TLS entre nodos habilitado por defecto en stacks TCP.

**Configuración mínima**

```yaml
# Operador (additionalOptions) o variables de entorno
- name: cache
  value: ispn
# cache-stack omitido → jdbc-ping por defecto
```

```bash
# CLI
bin/kc.sh start --cache=ispn
# o explícito:
bin/kc.sh start --cache=ispn --cache-stack=jdbc-ping
```

**Requisitos de red (jdbc-ping)**

| Puerto | Uso |
|--------|-----|
| 5432 (o tu DB) | PostgreSQL — también usado para registro de miembros del cluster |
| 7800 | Tráfico JGroups entre pods |
| 57800 | Failure detection |

---

## Stacks disponibles en 26.4

### Sin configuración adicional

| Stack | Transporte | Descubrimiento | Estado |
|-------|------------|----------------|--------|
| **`jdbc-ping`** | TCP | Base de datos (`JDBC_PING2`) | **Por defecto — usar este** |
| `jdbc-ping-udp` | UDP | Base de datos | Deprecado |

### Con configuración mínima

| Stack | Transporte | Descubrimiento | Configuración extra | Estado |
|-------|------------|----------------|---------------------|--------|
| **`kubernetes`** | TCP | DNS (`DNS_PING`) | `jgroups.dns.query` = FQDN del Service headless | Deprecado |
| `tcp` | TCP | Multicast (`MPING`) | `jgroups.mcast_addr` / `jgroups.mcast_port` únicos por cluster | Deprecado |
| `udp` | UDP | Multicast (`PING`) | Igual que `tcp` | Deprecado |

### Cloud (deprecados)

| Stack | Uso histórico | Estado |
|-------|---------------|--------|
| `ec2` | AWS tags | Deprecado |
| `azure` | Azure tags | Deprecado |
| `google` | GCP tags | Deprecado |

También puedes definir un stack personalizado en XML de Infinispan (avanzado).

---

## Stack `kubernetes` (DNS_PING) — lo que probamos en este repo

Usado en los manifests de `operador/` y `no-operador/` para demostrar clustering clásico en OpenShift/Kubernetes.

| Aspecto | Detalle |
|---------|---------|
| Protocolo JGroups | `DNS_PING` |
| Service | Headless (`clusterIP: None`) en puerto **7800** |
| Propiedad crítica | `jgroups.dns.query=<nombre>-discovery.<namespace>.svc.cluster.local` |

**Ejemplo sin operador** (`no-operador/manifests/keycloak.yaml`):

```yaml
- name: KC_CACHE
  value: ispn
- name: KC_CACHE_STACK
  value: kubernetes
- name: JAVA_OPTS_APPEND
  value: "-Djgroups.dns.query=keycloak-headless.rhbk-kubeping-plain.svc.cluster.local"
```

**Ejemplo con operador** — la variable `KC_JGROUPS_DNS_QUERY` en el CR **no siempre** llega a JGroups; en 26.4 fue necesario:

```yaml
env:
  - name: JAVA_OPTS_APPEND
    value: "-Djgroups.dns.query=rhbk-kc-discovery.rhbk-kubeping.svc.cluster.local"
```

El operador **sí** crea el Service `*-discovery`, pero **no** rellena automáticamente `dns_query` al usar `cache-stack: kubernetes`.

---

## Comparación rápida para elegir stack

| Criterio | `jdbc-ping` | `kubernetes` |
|----------|-------------|--------------|
| Complejidad en K8s | Baja | Media (headless + DNS) |
| Depende de DNS interno | No | Sí |
| Carga extra en DB | Pequeña (tabla ping) | No |
| Documentación / soporte a futuro | Recomendado | Deprecado |
| Caso de uso | **Producción nueva** | Legado, laboratorios, migración |

---

## ¿Cuándo dejarán de estar disponibles los stacks deprecados?

Red Hat y el proyecto upstream **no publican una fecha exacta** de eliminación para `kubernetes`, `tcp`, `udp`, etc.

Lo documentado en **RHBK 26.4**:

1. **Release Notes — Deprecated:** el stack `kubernetes` está deprecado y **se eliminará en una versión futura**; migrar a `jdbc-ping`.
2. **Server Configuration Guide:** los valores deprecados de `cache-stack` son: `azure`, `ec2`, `google`, `jdbc-ping-udp`, `kubernetes`, `tcp`, `udp`.
3. **Historial de versiones:**
   - **26.0:** `jdbc-ping` pasa a ser el default global.
   - **26.4:** el operador deja de usar `kubernetes` por defecto; el stack `kubernetes` se marca deprecado en release notes.

**Interpretación práctica (no oficial):**

| Hito | Comportamiento esperado |
|------|-------------------------|
| **26.4 (ahora)** | Stacks deprecados siguen funcionando; warnings en documentación. |
| **27.x (próxima major)** | Posible eliminación de algunos deprecados (Red Hat ya anunció removals concretos para otros APIs en 27.0, p. ej. campos del Account REST). |
| **Sin fecha en calendario** | Planificar migración a `jdbc-ping` **antes** de actualizar a la siguiente major, no esperar un EOL publicado mes a mes. |

Si hoy despliegas con `kubernetes`, funciona en 26.4, pero **no es la dirección del producto**.

---

## SSL / TLS en el cluster

| Capa | En CRC (este repo) |
|------|---------------------|
| Usuario → Route | TLS **edge** en el router de OpenShift (HTTPS externo, HTTP al pod). |
| Pod → Pod (JGroups) | Con stacks **TCP** (`jdbc-ping`, `kubernetes`): mTLS embebido **habilitado por defecto** entre nodos. |
| Pod → PostgreSQL | Sin TLS en los ejemplos de laboratorio (`postgres:15` sin certificados). |

Para producción, cifrar también el tráfico a PostgreSQL y valorar `cache-embedded-mtls-enabled` según la guía de RHBK.

---

## Despliegues en este repositorio

| Ruta | Namespace | Réplicas | Stack | Host (CRC) |
|------|-----------|----------|-------|------------|
| `operador/manifests/` | `rhbk-kubeping` | 3 | `kubernetes` + `JAVA_OPTS_APPEND` | `keycloak-kubeping.apps-crc.testing` |
| `no-operador/manifests/` | `rhbk-kubeping-plain` | 3 | `kubernetes` + headless Service | `keycloak-plain.apps-crc.testing` |

Comandos: ver [`commands`](commands).

**`/etc/hosts` (CRC):**

```
127.0.0.1 keycloak-kubeping.apps-crc.testing
127.0.0.1 keycloak-plain.apps-crc.testing
```

---

## Migración de `kubernetes` → `jdbc-ping`

Script automatizado (cluster en vivo + opción para actualizar manifests del repo):

```bash
# Ver qué haría sin aplicar cambios
./scripts/migrate-kubernetes-to-jdbc-ping.sh both --dry-run

# Migrar despliegue con operador
./scripts/migrate-kubernetes-to-jdbc-ping.sh operador

# Migrar despliegue sin operador (elimina keycloak-headless)
./scripts/migrate-kubernetes-to-jdbc-ping.sh plain

# Ambos + actualizar YAML en operador/ y no-operador/
./scripts/migrate-kubernetes-to-jdbc-ping.sh both --update-manifests
```

El script:

- **Operador:** quita `cache-stack`, `jgroups.dns.query`, `JAVA_OPTS_APPEND` del Keycloak CR y espera el rollout.
- **Sin operador:** quita `KC_CACHE_STACK=kubernetes`, `JAVA_OPTS_APPEND`, fija `jdbc-ping` y borra el Service headless.
- Verifica en logs `ISPN100010: Finished rebalance with members`.

Pasos manuales (si no usas el script):

1. Quitar `cache-stack: kubernetes` y opciones `jgroups.dns.query` / `JAVA_OPTS_APPEND` asociadas.
2. Dejar `cache: ispn` (o omitir stack → default `jdbc-ping`).
3. Asegurar que todos los pods alcanzan la **misma** base de datos.
4. Abrir puertos **7800** y **57800** entre pods (NetworkPolicy si aplica).
5. Redesplegar réplicas; verificar en logs: `ISPN100010: Finished rebalance with members [...]`.
6. El Service headless de discovery **ya no es necesario** (se puede eliminar).

No hace falta cambiar la Route ni el hostname del realm para esta migración.

---

## Verificación del cluster

```bash
# Pods listos
oc get pods -n <namespace> -l app=keycloak

# Logs de rebalance / miembros
oc logs -n <namespace> <pod> -c keycloak | grep -iE 'rebalance|members|ISPN100010'

# Con operador: servicio discovery (solo kubernetes)
oc get svc -n <namespace> | grep discovery
```

---

*Última revisión: documento alineado con RHBK / Keycloak **26.4** (mayo 2026).*
