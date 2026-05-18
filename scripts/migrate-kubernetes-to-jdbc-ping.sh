#!/usr/bin/env bash
# Migra despliegues de cache-stack kubernetes (DNS_PING) a jdbc-ping (default RHBK 26.4).
#
# Uso:
#   ./scripts/migrate-kubernetes-to-jdbc-ping.sh operador
#   ./scripts/migrate-kubernetes-to-jdbc-ping.sh plain
#   ./scripts/migrate-kubernetes-to-jdbc-ping.sh both
#   ./scripts/migrate-kubernetes-to-jdbc-ping.sh operador --dry-run
#   ./scripts/migrate-kubernetes-to-jdbc-ping.sh both --update-manifests
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NS_OPERADOR="${NS_OPERADOR:-rhbk-kubeping}"
KC_NAME="${KC_NAME:-rhbk-kc}"
NS_PLAIN="${NS_PLAIN:-rhbk-kubeping-plain}"
DEPLOY_PLAIN="${DEPLOY_PLAIN:-keycloak}"

DRY_RUN=false
UPDATE_MANIFESTS=false
SKIP_WAIT=false
KEEP_JGROUPS_DEBUG=false

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $*"
  else
    log "→ $*"
    "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando: $1"
}

usage() {
  cat <<'EOF'
Migra despliegues de cache-stack kubernetes (DNS_PING) a jdbc-ping (default RHBK 26.4).

Uso:
  ./scripts/migrate-kubernetes-to-jdbc-ping.sh operador
  ./scripts/migrate-kubernetes-to-jdbc-ping.sh plain
  ./scripts/migrate-kubernetes-to-jdbc-ping.sh both
  ./scripts/migrate-kubernetes-to-jdbc-ping.sh operador --dry-run
  ./scripts/migrate-kubernetes-to-jdbc-ping.sh both --update-manifests


Opciones:
  --dry-run              Solo muestra lo que haría
  --update-manifests     Actualiza YAML en operador/ y no-operador/ del repo
  --skip-wait            No espera rollout ni verifica logs
  --keep-jgroups-debug   Conserva log-category-org.jgroups en el CR (solo operador)
  -h, --help             Esta ayuda

Variables de entorno:
  NS_OPERADOR, KC_NAME, NS_PLAIN, DEPLOY_PLAIN
EOF
}

parse_args() {
  MODE="${1:-}"
  shift || true
  [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]] && { usage; exit 0; }
  [[ "$MODE" =~ ^(operador|plain|both)$ ]] || die "Modo inválido: $MODE (usa: operador | plain | both)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --update-manifests) UPDATE_MANIFESTS=true ;;
      --skip-wait) SKIP_WAIT=true ;;
      --keep-jgroups-debug) KEEP_JGROUPS_DEBUG=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opción desconocida: $1" ;;
    esac
    shift
  done
}

check_oc() {
  need_cmd oc
  need_cmd jq
  oc whoami >/dev/null 2>&1 || die "No hay sesión oc. Ejecuta: oc login ..."
}

wait_keycloak_ready() {
  local ns=$1 label_selector=$2
  [[ "$SKIP_WAIT" == true ]] && return 0

  log "Esperando pods Ready en ${ns}..."
  if [[ -n "$label_selector" ]]; then
    run oc wait --for=condition=ready pod -l "$label_selector" -n "$ns" --timeout=900s
  else
    run oc rollout status "deployment/${DEPLOY_PLAIN}" -n "$ns" --timeout=900s
  fi
}

verify_cluster_logs() {
  local ns=$1 pod_selector=$2 container=${3:-keycloak}
  [[ "$SKIP_WAIT" == true ]] && return 0

  local pod
  pod="$(oc get pods -n "$ns" -l "$pod_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "$pod" ]] && { warn "No hay pod para verificar logs en ${ns}"; return 0; }

  log "Verificando cluster en logs de ${pod}..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] oc logs -n ${ns} ${pod} -c ${container} | grep ISPN100010"
    return 0
  fi

  sleep 15
  if oc logs -n "$ns" "$pod" -c "$container" --tail=200 2>/dev/null \
    | grep -qE 'ISPN100010: Finished rebalance with members'; then
    log "OK: rebalance con múltiples miembros detectado en logs."
  else
    warn "No se encontró rebalance en logs aún. Revisa manualmente:"
    warn "  oc logs -n ${ns} ${pod} -c ${container} | grep -iE 'rebalance|members|ISPN100010'"
  fi
}

migrate_operador_cluster() {
  log "=== Migración operador: ${NS_OPERADOR}/${KC_NAME} ==="
  oc get keycloak "$KC_NAME" -n "$NS_OPERADOR" >/dev/null 2>&1 \
    || die "No existe Keycloak CR ${KC_NAME} en ${NS_OPERADOR}"

  local tmp filtered
  tmp="$(mktemp)"
  filtered="$(mktemp)"
  trap 'rm -f "$tmp" "$filtered"' RETURN

  oc get keycloak "$KC_NAME" -n "$NS_OPERADOR" -o json >"$tmp"

  jq --argjson keep_debug "$([[ "$KEEP_JGROUPS_DEBUG" == true ]] && echo true || echo false)" '
    .spec.additionalOptions = (
      (.spec.additionalOptions // [])
      | map(select(
          .name != "cache-stack"
          and .name != "jgroups.dns.query"
          and ( $keep_debug or .name != "log-category-org.jgroups" )
        ))
    )
    | if (.spec.additionalOptions | map(.name) | index("cache")) == null then
        .spec.additionalOptions += [{"name": "cache", "value": "ispn"}]
      else . end
    | .spec.env = ((.spec.env // []) | map(select(.name != "JAVA_OPTS_APPEND")))
    | if (.spec.env | length) == 0 then del(.spec.env) else . end
  ' "$tmp" >"$filtered"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Cambios en Keycloak CR:"
    jq '.spec.additionalOptions, .spec.env' "$filtered"
  else
    run oc apply -f "$filtered"
  fi

  wait_keycloak_ready "$NS_OPERADOR" "app=keycloak,app.kubernetes.io/instance=${KC_NAME}"
  verify_cluster_logs "$NS_OPERADOR" "app=keycloak,app.kubernetes.io/instance=${KC_NAME}"

  log "Operador: el Service *-discovery puede seguir existiendo; con jdbc-ping no se usa."
  log "Listo operador → https://keycloak-kubeping.apps-crc.testing (si aplica en CRC)"
}

migrate_plain_cluster() {
  log "=== Migración sin operador: ${NS_PLAIN}/${DEPLOY_PLAIN} ==="
  oc get deployment "$DEPLOY_PLAIN" -n "$NS_PLAIN" >/dev/null 2>&1 \
    || die "No existe Deployment ${DEPLOY_PLAIN} en ${NS_PLAIN}"

  # Quitar stack kubernetes y JAVA_OPTS_APPEND; jdbc-ping es el default si se omite KC_CACHE_STACK
  run oc set env "deployment/${DEPLOY_PLAIN}" -n "$NS_PLAIN" \
    KC_CACHE_STACK- \
    JAVA_OPTS_APPEND-

  # Opcional: fijar explícitamente (equivalente al default)
  run oc set env "deployment/${DEPLOY_PLAIN}" -n "$NS_PLAIN" \
    KC_CACHE_STACK=jdbc-ping

  log "Eliminando Service headless (ya no necesario con jdbc-ping)..."
  run oc delete service keycloak-headless -n "$NS_PLAIN" --ignore-not-found

  wait_keycloak_ready "$NS_PLAIN" ""
  verify_cluster_logs "$NS_PLAIN" "app=keycloak" "keycloak"

  log "Listo plain → https://keycloak-plain.apps-crc.testing (si aplica en CRC)"
}

update_manifest_operador() {
  local f="${REPO_ROOT}/operador/manifests/keycloak-cr.yaml"
  [[ -f "$f" ]] || { warn "No existe ${f}"; return 0; }

  log "Actualizando manifest: ${f}"
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] reescribir ${f} sin kubernetes / jgroups / JAVA_OPTS_APPEND"
    return 0
  fi

  cat >"$f" <<'YAML'
# RHBK 26.4 — HA con jdbc-ping (default 26.4, descubrimiento vía PostgreSQL)
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: rhbk-kc
  namespace: rhbk-kubeping
spec:
  instances: 3
  resources:
    requests:
      cpu: 500m
      memory: 896Mi
    limits:
      memory: 1536Mi
  additionalOptions:
    - name: cache
      value: ispn
    - name: log-level
      value: info
  db:
    vendor: postgres
    host: postgres-svc
    database: keycloak
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    httpEnabled: true
  ingress:
    enabled: false
  hostname:
    hostname: https://keycloak-kubeping.apps-crc.testing
    admin: https://keycloak-kubeping.apps-crc.testing
    strict: false
    backchannelDynamic: true
  proxy:
    headers: xforwarded
YAML
}

update_manifest_plain() {
  local f="${REPO_ROOT}/no-operador/manifests/keycloak.yaml"
  [[ -f "$f" ]] || { warn "No existe ${f}"; return 0; }

  log "Actualizando manifest: ${f}"
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] reescribir ${f} sin kubernetes / headless / JAVA_OPTS_APPEND"
    return 0
  fi

  cat >"$f" <<'YAML'
# RHBK Keycloak — Deployment sin operador, 3 réplicas, stack jdbc-ping (default 26.4)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: rhbk-kubeping-plain
  labels:
    app: keycloak
spec:
  replicas: 3
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: registry.redhat.io/rhbk/keycloak-rhel9:26.4
          args:
            - start
          env:
            - name: KC_HOSTNAME
              value: "https://keycloak-plain.apps-crc.testing"
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_HTTP_ENABLED
              value: "true"
            - name: KC_PROXY_HEADERS
              value: "xforwarded"
            - name: KC_HEALTH_ENABLED
              value: "true"
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: admin
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin-secret
                  key: password
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://postgres-svc:5432/keycloak
            - name: KC_DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: username
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: password
            - name: KC_CACHE
              value: ispn
            - name: KC_CACHE_STACK
              value: jdbc-ping
          ports:
            - name: http
              containerPort: 8080
            - name: jgroups
              containerPort: 7800
            - name: management
              containerPort: 9000
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 9000
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /health/live
              port: 9000
            initialDelaySeconds: 120
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: rhbk-kubeping-plain
spec:
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: rhbk-kubeping-plain
spec:
  host: keycloak-plain.apps-crc.testing
  to:
    kind: Service
    name: keycloak
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
YAML
}

main() {
  parse_args "$@"
  check_oc

  log "Modo: ${MODE} | dry-run=${DRY_RUN} | update-manifests=${UPDATE_MANIFESTS}"

  case "$MODE" in
    operador)
      migrate_operador_cluster
      [[ "$UPDATE_MANIFESTS" == true ]] && update_manifest_operador
      ;;
    plain)
      migrate_plain_cluster
      [[ "$UPDATE_MANIFESTS" == true ]] && update_manifest_plain
      ;;
    both)
      migrate_operador_cluster
      migrate_plain_cluster
      [[ "$UPDATE_MANIFESTS" == true ]] && { update_manifest_operador; update_manifest_plain; }
      ;;
  esac

  log "Migración finalizada."
  [[ "$UPDATE_MANIFESTS" == true ]] && log "Manifests del repo actualizados. Revisa con: git diff"
}

main "$@"
