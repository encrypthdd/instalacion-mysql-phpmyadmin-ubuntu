# Rulesets de protección de `main`

Configuración de la protección de rama, versionada aquí para poder revisarla y
reaplicarla. **Estos archivos no hacen nada por sí solos**: hay que importarlos
en GitHub.

## Cómo importarlos

Settings → Rules → Rulesets → menú `...` → **Import a ruleset** → elige el `.json`.

Tras importar, comprueba que el **Enforcement status** quedó en `Active` y pulsa
**Create**.

## Cuál usar

| Archivo | Para quién | Qué impide |
|---|---|---|
| `proteger-main.json` | Trabajando solo | Borrar la rama y reescribir historial con `push --force`. Los push directos a `main` siguen permitidos. |
| `proteger-main-estricto.json` | Con colaboradores | Lo anterior, más: todo cambio entra por pull request y el historial se mantiene lineal. |

Importa **uno de los dos**, no ambos: dos rulesets sobre la misma rama se suman,
y acabarías con las reglas estrictas sin querer.

## Notas

- `~DEFAULT_BRANCH` apunta siempre a la rama por defecto, así que la protección
  sigue en pie aunque algún día renombres `main`.
- `bypass_actors` está vacío a propósito: la regla **también te aplica a ti como
  propietario**. Si necesitas forzar algo puntualmente, desactiva el ruleset,
  hazlo, y vuelve a activarlo. Si prefieres poder saltártela siempre, añade un
  actor con `"actor_type": "RepositoryRole"` y el `actor_id` del rol admin.
- En el perfil estricto, `required_approving_review_count` está en `0` porque
  GitHub no te deja aprobar tus propios pull requests: con `1`, trabajando solo,
  te bloquearías a ti mismo. Súbelo a `1` cuando haya una segunda persona.

## Comprobar que está activo

```bash
git push --force origin main
```

Debe ser rechazado con `push declined due to repository rule violations`. Si pasa
sin error, el ruleset está en `Disabled` o no apunta a la rama correcta.
