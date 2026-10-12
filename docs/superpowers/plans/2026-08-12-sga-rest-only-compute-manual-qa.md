# QA manual — SG-A: REST-only en compute

Las operaciones de datos/lifecycle van por el bridge (no testeables en `flutter test`).
Verificar a mano contra una VM real, con `gcloud` instalado (auth aún lo usa):

- [ ] Lifecycle por REST: **Iniciar / Detener / Reiniciar / Suspender / Reanudar** una VM funcionan y muestran su notificación de éxito.
- [ ] Fallo de lifecycle: forzar un error (p. ej. permiso insuficiente) y confirmar que aparece el **error localizado** en el snackbar y **no** se cae a gcloud (sin proceso gcloud en segundo plano para la operación).
- [ ] Búsqueda manual de instancia (diálogo "añadir instancia"): un nombre **válido** la encuentra (método mostrado: "REST API"); un nombre **inexistente** muestra el error, sin fallback gcloud.
- [ ] Dashboard: la **lista de instancias** y el **selector de proyectos** siguen poblando con normalidad.
- [ ] Ningún flujo de datos/lifecycle lanza un proceso `gcloud compute …` (solo auth/túnel siguen usando gcloud en esta fase).
