// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Lightweight Cloud Connector';

  @override
  String get settingsLanguageTitle => 'Idioma';

  @override
  String get settingsLanguageSystem => 'Idioma del sistema';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonClose => 'Cerrar';

  @override
  String get commonSave => 'Guardar';

  @override
  String get commonDelete => 'Eliminar';

  @override
  String get commonRemove => 'Quitar';

  @override
  String get commonRetry => 'Reintentar';

  @override
  String get commonRefresh => 'Actualizar';

  @override
  String get commonCopy => 'Copiar';

  @override
  String get commonError => 'Error';

  @override
  String get commonWarning => 'Advertencia';

  @override
  String get commonOk => 'OK';

  @override
  String get commonYes => 'Sí';

  @override
  String get commonNo => 'No';

  @override
  String get commonConnect => 'Conectar';

  @override
  String get commonDisconnect => 'Desconectar';

  @override
  String get commonAdd => 'Añadir';

  @override
  String get commonEdit => 'Editar';

  @override
  String get commonLoading => 'Cargando…';

  @override
  String get commonNever => 'Nunca';

  @override
  String get accountManageTitle => 'Gestionar cuentas';

  @override
  String get accountActiveTunnelsWarning =>
      'Los túneles activos se desconectarán al cambiar de cuenta.';

  @override
  String get accountNoneFound => 'No se encontraron cuentas autenticadas.';

  @override
  String get accountActiveBadge => 'ACTIVA';

  @override
  String get accountSwitchButton => 'Cambiar';

  @override
  String accountSwitchedTo(String account) {
    return 'Cambiado a $account';
  }

  @override
  String get accountRemoveTooltip => 'Eliminar cuenta';

  @override
  String get accountAddButton => 'Añadir cuenta';

  @override
  String get accountRemoveTitle => 'Eliminar cuenta';

  @override
  String accountRemoveConfirm(String email) {
    return '¿Revocar credenciales de $email?';
  }

  @override
  String get accountActiveAccountWarning =>
      'Esta es la cuenta activa. Todos los túneles se desconectarán.';

  @override
  String get commonGcpErrorPermissionDenied =>
      'Acceso denegado. Verifique sus permisos de GCP.';

  @override
  String get commonGcpErrorNotFound => 'Recurso no encontrado.';

  @override
  String get commonGcpErrorUnauthenticated =>
      'Se requiere autenticación. Vuelva a iniciar sesión.';

  @override
  String get commonGcpErrorQuotaExceeded => 'Cuota de GCP excedida.';

  @override
  String get commonGcpErrorNetwork => 'Error de red. Verifique su conexión.';

  @override
  String get commonGcpErrorUnknown =>
      'Se produjo un error. Verifique su configuración.';

  @override
  String accountRemovedSnackbar(String email) {
    return 'Cuenta $email eliminada';
  }

  @override
  String get tunnelManagerTitle => 'Gestor de túneles';

  @override
  String tunnelTotalCount(int count) {
    return '$count Total';
  }

  @override
  String tunnelHealthyCount(int count) {
    return '$count Saludables';
  }

  @override
  String tunnelErrorCount(int count) {
    return '$count Con error';
  }

  @override
  String tunnelReconnectingCount(int count) {
    return '$count Reconectando';
  }

  @override
  String get tunnelNoActiveTunnels => 'No hay túneles activos';

  @override
  String get tunnelConnectPrompt =>
      'Conéctese a una instancia para crear un túnel';

  @override
  String get tunnelDisconnectAll => 'Desconectar todo';

  @override
  String get tunnelDisconnectAllTitle => '¿Desconectar todos los túneles?';

  @override
  String tunnelDisconnectAllConfirm(int count) {
    return 'Esto cerrará los $count túnel(es) activo(s).';
  }

  @override
  String get tunnelCleanupZombies => 'Limpiar túneles zombis';

  @override
  String get tunnelNoZombiesFound => 'No se encontraron túneles zombis';

  @override
  String tunnelCleanedUpZombies(int count) {
    return 'Se limpiaron $count túnel(es) zombi(s)';
  }

  @override
  String tunnelCleanupFailed(String error) {
    return 'Error en la limpieza: $error';
  }

  @override
  String get tunnelStatusReconnecting => 'Reconectando';

  @override
  String get tunnelStatusHealthy => 'Saludable';

  @override
  String get tunnelAutoReconnect => 'Reconexión automática';

  @override
  String get tunnelRetryNow => 'Reintentar ahora';

  @override
  String get doctorTitle => 'Diagnóstico de conectividad';

  @override
  String get doctorRunAgain => 'Ejecutar de nuevo';

  @override
  String get doctorRunning => 'Ejecutando…';

  @override
  String get doctorExportReport => 'Exportar informe';

  @override
  String doctorReportExported(String path) {
    return 'Informe exportado a: $path';
  }

  @override
  String get doctorCopyPath => 'Copiar ruta';

  @override
  String doctorExportFailed(String error) {
    return 'Error al exportar el informe: $error';
  }

  @override
  String get doctorConfirmFixTitle => 'Confirmar acción de corrección';

  @override
  String doctorConfirmStartVm(String instanceName) {
    return '¿Iniciar la instancia de VM \"$instanceName\"?';
  }

  @override
  String get doctorConfirmReauthenticate =>
      '¿Reautenticar con gcloud? Esto abrirá una ventana del navegador.';

  @override
  String doctorConfirmExecuteFix(String fixActionId) {
    return '¿Ejecutar la acción de corrección \"$fixActionId\"?';
  }

  @override
  String get doctorExecute => 'Ejecutar';

  @override
  String doctorFixFailed(String error) {
    return 'Error al corregir: $error';
  }

  @override
  String get doctorRunningChecks =>
      'Ejecutando comprobaciones de conectividad…';

  @override
  String commonErrorPrefix(String error) {
    return 'Error: $error';
  }

  @override
  String get doctorNoResultsYet => 'Aún no hay resultados';

  @override
  String get doctorCommandCopied => 'Comando copiado al portapapeles';

  @override
  String get doctorCategoryAuthentication => 'Autenticación';

  @override
  String get doctorCategoryProjectPermissions => 'Proyecto y permisos';

  @override
  String get doctorCategoryIapNetwork => 'IAP y red';

  @override
  String get doctorCategoryVmStatus => 'Estado de la VM';

  @override
  String get doctorCategoryLocalEnvironment => 'Entorno local';

  @override
  String doctorTotalDuration(int ms) {
    return 'Total: ${ms}ms';
  }

  @override
  String get doctorCopyCommand => 'Copiar comando';

  @override
  String get doctorFix => 'Corregir';

  @override
  String get dbConnectionTitle => 'Conexión a base de datos';

  @override
  String get dbTabNewConnection => 'Nueva conexión';

  @override
  String get dbTabSavedProfiles => 'Perfiles guardados';

  @override
  String dbCreatingTunnel(int port) {
    return 'Creando túnel al puerto $port…';
  }

  @override
  String get dbTunnelCreationFailed => 'No se pudo crear el túnel';

  @override
  String dbLaunched(String clientName) {
    return '$clientName iniciado';
  }

  @override
  String dbLaunchedFallback(String clientName) {
    return '$clientName iniciado (alternativa)';
  }

  @override
  String dbConnectionFailed(String error) {
    return 'Error de conexión: $error';
  }

  @override
  String get dbEnterProfileName => 'Introduzca un nombre de perfil';

  @override
  String dbProfileSaved(String name) {
    return 'Perfil \"$name\" guardado';
  }

  @override
  String get dbTypeLabel => 'Tipo de base de datos';

  @override
  String get dbRemotePortLabel => 'Puerto remoto';

  @override
  String get dbCustomPort => 'Puerto personalizado';

  @override
  String get dbDatabaseNameOptional => 'Nombre de la base de datos (opcional)';

  @override
  String get dbUsernameOptional => 'Usuario (opcional)';

  @override
  String get dbSqlClientLabel => 'Cliente SQL';

  @override
  String dbNoCompatibleClients(String dbType) {
    return 'No se encontraron clientes compatibles para $dbType.\nInstala uno de los clientes admitidos.';
  }

  @override
  String get dbAutoClient => 'Automático';

  @override
  String dbErrorLoadingClients(String error) {
    return 'Error al cargar los clientes: $error';
  }

  @override
  String get dbConnecting => 'Conectando…';

  @override
  String get dbConnectAndLaunch => 'Conectar e iniciar';

  @override
  String get dbSaveAsProfileLabel => 'Guardar como perfil';

  @override
  String get dbProfileNameLabel => 'Nombre del perfil';

  @override
  String get dbProfileNameHint => 'p. ej., Production MySQL';

  @override
  String get dbNoSavedProfiles => 'No hay perfiles guardados';

  @override
  String get dbNoSavedProfilesHint =>
      'Crea una conexión y guárdala como perfil para acceder rápidamente';

  @override
  String get dbDeleteProfileTitle => 'Eliminar perfil';

  @override
  String dbDeleteProfileConfirm(String name) {
    return '¿Seguro que desea eliminar \"$name\"?';
  }

  @override
  String dbTypePortLabel(String dbType, int port) {
    return '$dbType (Puerto $port)';
  }

  @override
  String dbDatabaseLabel(String name) {
    return 'Base de datos: $name';
  }

  @override
  String dbClientLabel(String clientName) {
    return 'Cliente: $clientName';
  }

  @override
  String get dbDeleteProfileTooltip => 'Eliminar perfil';

  @override
  String get winCredTitle => 'Contraseña de Windows';

  @override
  String get winCredGeneratePasswordTab => 'Generar contraseña';

  @override
  String get winCredStoredCredentialsTab => 'Credenciales guardadas';

  @override
  String get winCredInfoBox =>
      'Genere una contraseña nueva de Windows o restablezca una existente. La contraseña se almacenará de forma segura en el almacén de claves del sistema.';

  @override
  String get commonUsernameLabel => 'Usuario';

  @override
  String get winCredUsernameHint =>
      'Nombre de usuario de Windows (p. ej., Administrator)';

  @override
  String get winCredEmailLabel => 'Correo electrónico';

  @override
  String get winCredEmailHint =>
      'Dirección de correo electrónico (para seguimiento de GCP)';

  @override
  String get winCredGenerateNew => 'Generar nueva';

  @override
  String get winCredResetPassword => 'Restablecer contraseña';

  @override
  String get winCredWaitingForAgent =>
      'Esperando respuesta del agente invitado de Windows…';

  @override
  String get winCredMayTake60s => 'Esto puede tardar hasta 60 segundos';

  @override
  String get winCredGeneratedCredential => 'Credencial generada';

  @override
  String get winCredNoStoredCredentials => 'No hay credenciales guardadas';

  @override
  String get winCredNoStoredCredentialsHint =>
      'Genere una contraseña para una VM de Windows para guardarla aquí';

  @override
  String get winCredClearAll => 'Borrar todo';

  @override
  String get winCredUsernameField => 'Usuario: ';

  @override
  String get winCredPasswordField => 'Contraseña: ';

  @override
  String get winCredCopyUsernameTooltip => 'Copiar usuario';

  @override
  String get winCredCopyPasswordTooltip => 'Copiar contraseña';

  @override
  String get winCredHidePassword => 'Ocultar contraseña';

  @override
  String get winCredShowPassword => 'Mostrar contraseña';

  @override
  String get commonCurrentChip => 'Actual';

  @override
  String get commonPleaseEnterUsername => 'Introduzca un nombre de usuario';

  @override
  String get winCredPasswordWord => 'Contraseña';

  @override
  String winCredCopiedToClipboard(String label) {
    return '$label copiado al portapapeles';
  }

  @override
  String winCredCopiedToClipboardSensitive(String label) {
    return '$label copiado al portapapeles (se borra en 30 s)';
  }

  @override
  String get winCredDeleteCredentialTitle => 'Eliminar credencial';

  @override
  String winCredDeleteCredentialConfirm(String username, String instanceName) {
    return '¿Desea eliminar la credencial guardada para $username@$instanceName?';
  }

  @override
  String get winCredClearAllTitle => 'Eliminar todas las credenciales';

  @override
  String get winCredClearAllConfirm =>
      '¿Desea eliminar TODAS las credenciales guardadas de Windows? Esta acción no se puede deshacer.';

  @override
  String get sshfsDialogTitle => 'Montar sistema de archivos remoto';

  @override
  String get sshfsUnavailableDefaultIssue => 'SSHFS no está disponible';

  @override
  String get sshfsMountAction => 'Montar';

  @override
  String get sshfsActiveMountsTab => 'Montajes activos';

  @override
  String get sshfsNotAvailableTitle => 'SSHFS no disponible';

  @override
  String sshfsMountInfoText(String instanceName, int port) {
    return 'Se montará un directorio remoto de $instanceName en el sistema de archivos local. Se utilizará el túnel del puerto $port para la conexión.';
  }

  @override
  String get sshfsUsernameLabel => 'Usuario SSH';

  @override
  String get sshfsUsernameHint => 'Usuario en la VM remota';

  @override
  String get sshfsRemotePathLabel => 'Ruta remota';

  @override
  String get sshfsLocalMountPointLabel => 'Punto de montaje local';

  @override
  String get sshfsResetToDefaultTooltip => 'Restablecer valor predeterminado';

  @override
  String get sshfsMountOptionsTitle => 'Opciones de montaje';

  @override
  String get sshfsReadOnlyOption => 'Solo lectura';

  @override
  String get sshfsCacheOption => 'Caché';

  @override
  String get sshfsCompressionOption => 'Compresión';

  @override
  String get sshfsAutoReconnectOption => 'Reconexión automática';

  @override
  String get sshfsMountingButton => 'Montando…';

  @override
  String get sshfsNoActiveMountsTitle => 'No hay montajes activos';

  @override
  String get sshfsNoActiveMountsSubtitle =>
      'Monte un directorio remoto para verlo aquí';

  @override
  String sshfsActiveMountsCount(int count) {
    return '$count montajes activos';
  }

  @override
  String get sshfsUnmountAllButton => 'Desmontar todo';

  @override
  String sshfsThisInstance(String instanceName) {
    return 'Esta instancia ($instanceName)';
  }

  @override
  String get sshfsInfoProject => 'Proyecto';

  @override
  String get sshfsInfoZone => 'Zona';

  @override
  String get sshfsInfoLocalMount => 'Montaje local';

  @override
  String get sshfsInfoTunnelPort => 'Puerto del túnel';

  @override
  String get sshfsOpenButton => 'Abrir';

  @override
  String get sshfsUnmountButton => 'Desmontar';

  @override
  String get sshfsRemotePathRequired => 'Introduzca una ruta remota';

  @override
  String get sshfsLocalPathRequired => 'Introduzca un punto de montaje local';

  @override
  String get sshfsUnmountAllConfirmMessage =>
      '¿Desea desmontar todos los montajes SSHFS?';

  @override
  String get settingsTitle => 'Configuración';

  @override
  String get settingsAppearanceTitle => 'Apariencia';

  @override
  String get settingsAutoRefreshTitle => 'Actualización automática';

  @override
  String get settingsEnableAutoRefresh => 'Habilitar actualización automática';

  @override
  String get settingsAutoRefreshSubtitle =>
      'Actualizar automáticamente la lista de instancias';

  @override
  String get settingsRefreshIntervalLabel => 'Intervalo de actualización';

  @override
  String settingsUpdateEverySeconds(int seconds) {
    return 'Actualizar cada $seconds segundos';
  }

  @override
  String get settingsIntervalDisabled => 'Deshabilitado';

  @override
  String get settingsInterval10s => '10 segundos';

  @override
  String get settingsInterval30s => '30 segundos';

  @override
  String get settingsInterval60s => '1 minuto';

  @override
  String get settingsInterval120s => '2 minutos';

  @override
  String get settingsInterval300s => '5 minutos';

  @override
  String get settingsCustomInterval => 'Intervalo personalizado';

  @override
  String get settingsCustomIntervalSubtitle =>
      'Especifique un intervalo personalizado (5-600 s)';

  @override
  String get settingsSecondsLabel => 'Segundos';

  @override
  String get settingsSecondsHelper => 'Mín.: 5, Máx.: 600';

  @override
  String get settingsInvalidNumber => 'Introduzca un número válido';

  @override
  String get settingsIntervalRange =>
      'El intervalo debe estar entre 5 y 600 segundos';

  @override
  String settingsRefreshIntervalSet(int seconds) {
    return 'Intervalo de actualización establecido en $seconds segundos';
  }

  @override
  String get settingsSetButton => 'Establecer';

  @override
  String get settingsNotificationsTitle => 'Notificaciones';

  @override
  String get settingsEnableNotifications =>
      'Habilitar notificaciones de escritorio';

  @override
  String get settingsNotificationsSubtitle =>
      'Reciba notificaciones sobre cambios de estado de la VM y eventos';

  @override
  String get settingsNotifiedAboutLabel => 'Se le notificará sobre:';

  @override
  String get settingsNotifyVmState =>
      '• Cambios de estado de la VM (RUNNING ↔ STOPPED)';

  @override
  String get settingsNotifyIapFailures => '• Fallos del túnel IAP';

  @override
  String get settingsNotifyLifecycleResults =>
      '• Resultados de operaciones de ciclo de vida (iniciar/detener/reiniciar)';

  @override
  String get settingsSystemDependenciesTitle => 'Dependencias del sistema';

  @override
  String get settingsRdpClientTitle => 'Cliente RDP';

  @override
  String get settingsVncClientTitle => 'Cliente VNC';

  @override
  String get settingsAboutTitle => 'Acerca de';

  @override
  String get settingsEditionsDescription =>
      'Las ediciones siguen un ciclo semestral (AAH#). 26H2 corresponde al segundo semestre de 2026. Las compilaciones aportan correcciones continuas entre ediciones.';

  @override
  String get settingsSupportDevelopmentTitle => 'Apoyar el desarrollo';

  @override
  String get settingsSupportMessage =>
      'Si esta herramienta le resulta útil, considere apoyar su desarrollo.';

  @override
  String get settingsChooseThemeLabel => 'Elija su tema preferido:';

  @override
  String get settingsThemeLight => 'Claro';

  @override
  String get settingsThemeDark => 'Oscuro';

  @override
  String get settingsThemeSystem => 'Sistema (automático)';

  @override
  String get settingsThemeLightDesc => 'Usar siempre el tema claro';

  @override
  String get settingsThemeDarkDesc => 'Usar siempre el tema oscuro';

  @override
  String get settingsThemeSystemDesc => 'Seguir la preferencia del sistema';

  @override
  String get settingsNoRdpClients =>
      'No se detectaron clientes RDP. Instale uno de los siguientes: Remmina, FreeRDP, KRDC o GNOME Connections.';

  @override
  String get settingsSelectRdpClient => 'Seleccione su cliente RDP preferido:';

  @override
  String get settingsNotInstalled => 'No instalado';

  @override
  String get settingsInstallClientHint => 'Instale este cliente para usarlo';

  @override
  String settingsRdpClientSet(String name) {
    return 'Cliente RDP establecido en $name';
  }

  @override
  String get settingsClientTip =>
      '💡 Consejo: si su cliente preferido no está disponible, la aplicación probará automáticamente otros clientes instalados.';

  @override
  String settingsErrorDetectingRdp(String error) {
    return 'Error al detectar clientes RDP: $error';
  }

  @override
  String get settingsNoVncClients =>
      'No se detectaron clientes VNC. Instale uno de los siguientes: Remmina, TigerVNC, KRDC o Vinagre.';

  @override
  String get settingsSelectVncClient => 'Seleccione su cliente VNC preferido:';

  @override
  String settingsVncClientSet(String name) {
    return 'Cliente VNC establecido en $name';
  }

  @override
  String settingsErrorDetectingVnc(String error) {
    return 'Error al detectar clientes VNC: $error';
  }

  @override
  String get settingsDependencyStatusLabel =>
      'Estado de las herramientas utilizadas por la aplicación:';

  @override
  String get settingsDepRdpClients => 'Clientes RDP';

  @override
  String get settingsDepVncClients => 'Clientes VNC';

  @override
  String get settingsDepSqlClients => 'Clientes SQL';

  @override
  String get settingsRequiredBadge => 'Obligatorio';

  @override
  String settingsInstalledCount(int count) {
    return '$count instalado(s)';
  }

  @override
  String get settingsInstalledLabel => 'Instalado';

  @override
  String get settingsNotFound => 'No encontrado';

  @override
  String settingsErrorCheckingDeps(String error) {
    return 'Error al comprobar dependencias: $error';
  }

  @override
  String get settingsRdpDescRemmina =>
      'Completo, admite archivos de configuración';

  @override
  String get settingsRdpDescFreeRdp =>
      'Basado en línea de comandos, ampliamente disponible';

  @override
  String get settingsRdpDescKrdc =>
      'Cliente de escritorio remoto predeterminado de KDE';

  @override
  String get settingsRdpDescGnome =>
      'Aplicación moderna de escritorio remoto de GNOME';

  @override
  String get settingsRdpDescMstsc =>
      'Cliente de escritorio remoto nativo de Windows';

  @override
  String get settingsVncDescRemmina => 'Completo, admite RDP y VNC';

  @override
  String get settingsVncDescTigerVnc => 'Visor VNC de alto rendimiento';

  @override
  String get settingsVncDescKrdc => 'Cliente VNC y RDP de KDE';

  @override
  String get settingsVncDescVinagre => 'Visor VNC de GNOME';

  @override
  String commonEditionLabel(String version) {
    return 'Edición $version';
  }

  @override
  String commonBuildLabel(String build) {
    return 'Compilación $build';
  }

  @override
  String get manualInstanceTitle => 'Añadir instancia manualmente';

  @override
  String get manualInstanceDescription =>
      'Añada una instancia cuando disponga de permiso de visualización pero no de permiso de lista.';

  @override
  String get manualInstanceProjectIdLabel => 'ID del proyecto';

  @override
  String get manualInstanceProjectIdHint => 'p. ej., my-project-123';

  @override
  String get manualInstanceProjectIdRequired =>
      'El ID del proyecto es obligatorio';

  @override
  String get manualInstanceZoneLabel => 'Zona';

  @override
  String get manualInstanceZoneHint => 'p. ej., us-central1-a';

  @override
  String get manualInstanceZoneRequired => 'La zona es obligatoria';

  @override
  String get manualInstanceNameLabel => 'Nombre de la instancia';

  @override
  String get manualInstanceNameHint => 'p. ej., my-vm-instance';

  @override
  String get manualInstanceNameRequired =>
      'El nombre de la instancia es obligatorio';

  @override
  String get manualInstanceSearching => 'Buscando…';

  @override
  String get manualInstanceSearchButton => 'Buscar instancia';

  @override
  String get manualInstanceFoundTitle => '¡Instancia encontrada!';

  @override
  String manualInstanceViaMethod(String method) {
    return 'vía $method';
  }

  @override
  String get manualInstanceFieldName => 'Nombre';

  @override
  String get manualInstanceFieldStatus => 'Estado';

  @override
  String get manualInstanceFieldMachineType => 'Tipo de máquina';

  @override
  String get manualInstanceAddButton => 'Añadir instancia';

  @override
  String get snapshotDialogTitle => 'Snapshots de VM';

  @override
  String get snapshotTabList => 'Snapshots';

  @override
  String snapshotTabListWithCount(int count) {
    return 'Snapshots ($count)';
  }

  @override
  String get snapshotTabCreate => 'Crear';

  @override
  String get snapshotEmptyList => 'No hay snapshots para esta VM';

  @override
  String snapshotMetaCreated(String date) {
    return 'Creado: $date';
  }

  @override
  String snapshotMetaDisk(String size) {
    return 'Disco: $size';
  }

  @override
  String snapshotMetaStored(String size) {
    return 'Almacenado: $size';
  }

  @override
  String snapshotMetaSource(String disk) {
    return 'Origen: $disk';
  }

  @override
  String get snapshotRestoreDiskButton => 'Restaurar disco';

  @override
  String get snapshotDeleteTitle => 'Eliminar snapshot';

  @override
  String get snapshotDeleteConfirm =>
      '¿Eliminar permanentemente este snapshot?';

  @override
  String snapshotDeletedSnackbar(String name) {
    return 'Snapshot \"$name\" eliminado.';
  }

  @override
  String snapshotDeleteError(String error) {
    return 'Error al eliminar: $error';
  }

  @override
  String get snapshotRestoreTitle => 'Restaurar desde snapshot';

  @override
  String snapshotRestoreDescription(String name) {
    return 'Se creará un nuevo disco a partir del snapshot \"$name\".';
  }

  @override
  String get snapshotRestoreVmNote =>
      'La VM no se modifica automáticamente — se proporcionarán los comandos de gcloud para hacer el cambio.';

  @override
  String get snapshotNewDiskNameLabel => 'Nombre del nuevo disco';

  @override
  String get snapshotCreateDiskButton => 'Crear disco';

  @override
  String get snapshotCreatingDiskFromSnapshot =>
      'Creando disco desde snapshot…';

  @override
  String snapshotCreateDiskError(String error) {
    return 'Error al crear disco: $error';
  }

  @override
  String get snapshotDiskCreatedTitle => 'Disco creado desde snapshot';

  @override
  String snapshotDiskCreatedMessage(String name, String zone) {
    return 'Disco \"$name\" creado en $zone.';
  }

  @override
  String get snapshotRestoreCommandsIntro =>
      'Para restaurar la VM, ejecute estos comandos:';

  @override
  String get snapshotCopyCommandsButton => 'Copiar comandos';

  @override
  String get snapshotCommandsCopiedSnackbar =>
      'Comandos copiados al portapapeles';

  @override
  String get snapshotNameRequired => 'El nombre es obligatorio';

  @override
  String get snapshotNameMaxLength => 'Máximo 63 caracteres';

  @override
  String get snapshotNameMustStartLowercase =>
      'Debe comenzar con una letra minúscula';

  @override
  String get snapshotNameInvalidChars =>
      'Solo letras minúsculas, dígitos y guiones';

  @override
  String get snapshotNameNoTrailingHyphen => 'No puede terminar con guión';

  @override
  String snapshotCreatedSnackbar(String name) {
    return 'Snapshot \"$name\" creado. Puede tardar unos minutos en aparecer como READY.';
  }

  @override
  String snapshotCreateError(String error) {
    return 'Error al crear snapshot: $error';
  }

  @override
  String get snapshotNameFieldLabel => 'Nombre del snapshot *';

  @override
  String get snapshotNameFieldHelper =>
      'Solo letras minúsculas, dígitos y guiones. Máx 63 caracteres.';

  @override
  String get snapshotDescriptionFieldLabel => 'Descripción (opcional)';

  @override
  String get snapshotCreateButton => 'Crear Snapshot';

  @override
  String get snapshotCreateDurationNote =>
      'Los snapshots pueden tardar 2–5 minutos en completarse.';

  @override
  String get snapshotCreatingOverlay =>
      'Creando snapshot…\nEsto puede tardar varios minutos.';

  @override
  String get snapshotDetectingBootDisk => 'Detectando disco boot…';

  @override
  String snapshotBootDiskDetectError(String error) {
    return 'No se pudo detectar el disco boot: $error';
  }

  @override
  String get snapshotBootDiskLabel => 'Disco boot:';

  @override
  String get clientTestTitle => 'Prueba de bibliotecas de cliente';

  @override
  String get clientTestTabApi => 'Pruebas de API';

  @override
  String get clientTestTabLifecycle => 'Operaciones de ciclo de vida';

  @override
  String get clientTestTabPerformance => 'Rendimiento';

  @override
  String get clientTestRunAllTooltip => 'Ejecutar todas las pruebas';

  @override
  String get clientTestRunningAll => 'Ejecutando todas las pruebas…';

  @override
  String get clientTestLabelClientLibs => 'Bibliotecas de cliente';

  @override
  String get clientTestHeaderTitle =>
      'Integración de bibliotecas de cliente de Google Cloud';

  @override
  String get clientTestHeaderDescription =>
      'Pruebe y compare la nueva integración de bibliotecas de cliente con la CLI tradicional de gcloud. Las bibliotecas de cliente usan llamadas directas a la API REST para obtener un mejor rendimiento.';

  @override
  String get clientTestAuthTitle => 'Prueba de autenticación';

  @override
  String get clientTestRetryAuth => 'Reintentar autenticación';

  @override
  String get clientTestProjectsComparisonTitle =>
      'Comparación de listado de proyectos';

  @override
  String get clientTestNoProjectsFound => 'No se encontraron proyectos';

  @override
  String clientTestFoundProjectsCount(int count) {
    return 'Se encontraron $count proyectos';
  }

  @override
  String clientTestAndMoreCount(int count) {
    return '… y $count más';
  }

  @override
  String get clientTestAuthenticateFirst => 'Autentíquese primero con gcloud';

  @override
  String get clientTestPerfBenchmarkTitle => 'Prueba de rendimiento';

  @override
  String get clientTestBenchmarkDescription =>
      'Mide el tiempo necesario para listar todos los proyectos con ambos métodos.';

  @override
  String get clientTestRunningBenchmark => 'Ejecutando prueba de rendimiento…';

  @override
  String get clientTestRunBenchmarkButton => 'Ejecutar prueba de rendimiento';

  @override
  String get clientTestComputeInstancesTitle => 'Instancias de Compute Engine';

  @override
  String get clientTestSelectProjectHint =>
      'Seleccione un proyecto en el panel principal para probar el listado de instancias.';

  @override
  String get clientTestNoInstancesFound => 'No se encontraron instancias';

  @override
  String clientTestFoundInstancesCount(int count) {
    return 'Se encontraron $count instancias';
  }

  @override
  String get clientTestRefreshBothButton => 'Actualizar ambos';

  @override
  String get clientTestLifecycleTitle =>
      'Prueba de operaciones de ciclo de vida';

  @override
  String get clientTestLifecycleDescription =>
      'Pruebe las operaciones de ciclo de vida de la VM (iniciar/detener/reiniciar) usando la CLI y las bibliotecas de cliente. Seleccione una instancia en el panel principal para comenzar la prueba.';

  @override
  String get clientTestSelectProjectInstanceHint =>
      'Seleccione un proyecto y una instancia en el panel principal';

  @override
  String clientTestInstanceStatusZone(String status, String zone) {
    return 'Estado: $status • Zona: $zone';
  }

  @override
  String clientTestCurrentlyTestingWith(String method) {
    return 'Prueba actual con: $method';
  }

  @override
  String get clientTestTestOperationsLabel => 'Operaciones de prueba:';

  @override
  String get clientTestStartingInstance => 'Iniciando instancia…';

  @override
  String get clientTestInstanceStartedSuccess =>
      'Instancia iniciada correctamente.';

  @override
  String get clientTestStartInstanceButton => 'Iniciar instancia';

  @override
  String get clientTestStoppingInstance => 'Deteniendo instancia…';

  @override
  String get clientTestInstanceStoppedSuccess =>
      'Instancia detenida correctamente.';

  @override
  String get clientTestStopInstanceButton => 'Detener instancia';

  @override
  String get clientTestResettingInstance => 'Reiniciando instancia…';

  @override
  String get clientTestInstanceResetSuccess =>
      'Instancia reiniciada correctamente.';

  @override
  String get clientTestResetInstanceButton => 'Reiniciar instancia';

  @override
  String get clientTestTestingTipsTitle => 'Consejos de prueba';

  @override
  String get clientTestTestingTipsBody =>
      '• Cambie el método de API en la AppBar del panel principal para probar ambas implementaciones\n• Las operaciones tardan entre 30 y 120 segundos en completarse\n• Observe la consola para obtener información detallada de tiempos\n• Las bibliotecas de cliente deberían ser algo más rápidas al usar llamadas directas a la API';

  @override
  String get clientTestPerfStatsTitle => 'Estadísticas de rendimiento';

  @override
  String get clientTestPerfStatsDescription =>
      'Datos de rendimiento agregados que comparan la CLI de gcloud con las bibliotecas de cliente. Ejecute pruebas de rendimiento desde la pestaña de pruebas de API para generar estadísticas.';

  @override
  String get clientTestBenchmarkSummaryTitle =>
      'Resumen de resultados de la prueba de rendimiento';

  @override
  String get clientTestMetricSpeedup => 'Aceleración';

  @override
  String get clientTestMetricImprovement => 'Mejora';

  @override
  String get clientTestRunBenchmarkHint =>
      'Ejecute la prueba de rendimiento desde la pestaña de pruebas de API para ver los resultados';

  @override
  String get clientTestExpectedGainsTitle => 'Mejoras de rendimiento esperadas';

  @override
  String get clientTestOpListProjects => 'Listar proyectos';

  @override
  String get clientTestOpListInstances => 'Listar instancias';

  @override
  String get clientTestOpStartStopInstance => 'Iniciar/detener instancia';

  @override
  String get clientTestReasonListProjects =>
      'Llamadas a la API más rápidas, sin sobrecarga de procesos';

  @override
  String get clientTestReasonListInstances =>
      'API REST directa frente al análisis de JSON de la CLI';

  @override
  String get clientTestReasonStartStop =>
      'Menor latencia gracias a la API directa';

  @override
  String get clientTestReasonReset => 'Diferencia de sobrecarga mínima';

  @override
  String get clientTestExpectedGainsFooter =>
      'Las bibliotecas de cliente destacan en operaciones de alta frecuencia. Cuantas más llamadas a la API, mayor es el ahorro acumulado de tiempo.';

  @override
  String get diagTitle => 'Diagnóstico de VM';

  @override
  String diagSubtitle(String instanceName, String zone) {
    return '$instanceName ($zone)';
  }

  @override
  String get diagTabSerialConsole => 'Consola serie';

  @override
  String get diagTabDiagnostics => 'Diagnóstico';

  @override
  String get diagTabAuditLogs => 'Registros de auditoría';

  @override
  String diagLogsExportedTo(String path) {
    return 'Registros exportados a: $path';
  }

  @override
  String get diagOpenAction => 'Abrir';

  @override
  String diagExportFailed(String error) {
    return 'Error al exportar: $error';
  }

  @override
  String get diagPortLabel => 'Puerto: ';

  @override
  String get diagSearchHint => 'Buscar en los registros…';

  @override
  String get diagAutoScrollTooltip => 'Desplazamiento automático';

  @override
  String get diagStopAutoRefreshTooltip => 'Detener actualización automática';

  @override
  String get diagAutoRefreshTooltip => 'Actualización automática (5 s)';

  @override
  String get diagExportLogsTooltip => 'Exportar registros';

  @override
  String get diagCopyToClipboardTooltip => 'Copiar al portapapeles';

  @override
  String get diagCopiedToClipboard => 'Copiado al portapapeles';

  @override
  String diagFetchedAt(String timestamp) {
    return 'Obtenido: $timestamp';
  }

  @override
  String diagLinesCount(int count) {
    return '$count líneas';
  }

  @override
  String diagLinesCountFiltered(int count) {
    return '$count líneas (filtrado)';
  }

  @override
  String get diagSerialPortDisabledTitle =>
      'Registro de puerto serie deshabilitado';

  @override
  String get diagErrorLoadingSerialTitle => 'Error al cargar la salida serie';

  @override
  String get diagCopyEnableCommandButton => 'Copiar comando de habilitación';

  @override
  String get diagCommandCopiedToClipboard => 'Comando copiado al portapapeles';

  @override
  String get diagNoData => 'Sin datos';

  @override
  String get diagInstanceStatusTitle => 'Estado de la instancia';

  @override
  String get diagLabelStatus => 'Estado';

  @override
  String get diagLabelMachineType => 'Tipo de máquina';

  @override
  String get diagLabelZone => 'Zona';

  @override
  String get diagLabelProject => 'Proyecto';

  @override
  String get diagLabelCreated => 'Creada';

  @override
  String get diagLabelLastStarted => 'Último inicio';

  @override
  String get diagLabelLastStopped => 'Última detención';

  @override
  String get diagGuestAgentTitle => 'Agente invitado';

  @override
  String get diagStatusReporting => 'Informando';

  @override
  String get diagStatusNotReporting => 'Sin informar';

  @override
  String get diagLabelOsType => 'Tipo de SO';

  @override
  String get diagLabelOsVersion => 'Versión de SO';

  @override
  String get diagLabelLastHeartbeat => 'Última señal';

  @override
  String get diagGuestAgentWarning =>
      'Es posible que el agente invitado no esté instalado o en ejecución.';

  @override
  String get diagNetworkInterfacesTitle => 'Interfaces de red';

  @override
  String diagInterfaceNumber(int number) {
    return 'Interfaz $number';
  }

  @override
  String get diagLabelNetwork => 'Red';

  @override
  String get diagLabelSubnetwork => 'Subred';

  @override
  String get diagLabelInternalIp => 'IP interna';

  @override
  String get diagLabelExternalIp => 'IP externa';

  @override
  String get diagValueNone => 'Ninguna';

  @override
  String get diagLabelTier => 'Nivel';

  @override
  String get diagDisksTitle => 'Discos';

  @override
  String get diagBootChip => 'Arranque';

  @override
  String get diagLabelType => 'Tipo';

  @override
  String get diagLabelSize => 'Tamaño';

  @override
  String diagSizeGb(int size) {
    return '$size GB';
  }

  @override
  String get diagLabelMode => 'Modo';

  @override
  String get diagLabelAutoDelete => 'Eliminación automática';

  @override
  String get diagLabelsTitle => 'Etiquetas';

  @override
  String diagLabelKeyValue(String key, String value) {
    return '$key: $value';
  }

  @override
  String get diagLastLabel => 'Periodo: ';

  @override
  String get diagHours1 => '1 hora';

  @override
  String get diagHours6 => '6 horas';

  @override
  String get diagHours24 => '24 horas';

  @override
  String get diagDays3 => '3 días';

  @override
  String get diagDays7 => '7 días';

  @override
  String get diagThisInstanceOnly => 'Solo esta instancia';

  @override
  String get diagPermissionDeniedTitle => 'Permiso denegado';

  @override
  String get diagErrorLoadingAuditLogsTitle =>
      'Error al cargar los registros de auditoría';

  @override
  String get diagNoAuditLogsFound =>
      'No se encontraron registros de auditoría en el intervalo de tiempo seleccionado';

  @override
  String get diagUnknownOperation => 'Operación desconocida';

  @override
  String get diagSystemFallback => 'Sistema';

  @override
  String diagLogSubtitle(String timestamp, String principal) {
    return '$timestamp - $principal';
  }

  @override
  String get diagLabelSeverity => 'Gravedad';

  @override
  String get diagLabelResource => 'Recurso';

  @override
  String get diagValueNa => 'N/D';

  @override
  String get diagLabelResourceType => 'Tipo de recurso';

  @override
  String get diagLabelLog => 'Registro';

  @override
  String get diagLabelRequest => 'Solicitud';

  @override
  String sftpErrorLoadDirectory(String path, String error) {
    return 'No se pudo cargar el directorio \"$path\": $error\n\nCompruebe los permisos y la conectividad de red.';
  }

  @override
  String sftpUploadingFile(String fileName) {
    return 'Subiendo $fileName…';
  }

  @override
  String sftpErrorUploadFile(String fileName, String error) {
    return 'No se pudo subir \"$fileName\": $error\n\nCompruebe los permisos de archivo y el espacio en disco.';
  }

  @override
  String sftpUploadingBatch(int current, int total, String fileName) {
    return 'Subiendo $current/$total: $fileName…';
  }

  @override
  String sftpUploadingFolder(String folderName) {
    return 'Subiendo la carpeta $folderName…';
  }

  @override
  String sftpUploadingFolderProgress(int current, int total, String fileName) {
    return 'Subiendo $current/$total: $fileName…';
  }

  @override
  String sftpErrorUploadFolder(String error) {
    return 'No se pudo subir la carpeta: $error\n\nAlgunos archivos podrían haberse subido correctamente.';
  }

  @override
  String get sftpErrorFolderNameInvalid => 'Nombre de carpeta no válido.';

  @override
  String sftpErrorUploadBatch(String error) {
    return 'No se pudieron subir los archivos: $error\n\nAlgunos archivos podrían haberse subido correctamente.';
  }

  @override
  String sftpDownloadingFile(String fileName) {
    return 'Descargando $fileName…';
  }

  @override
  String sftpErrorDownloadFile(String fileName, String error) {
    return 'No se pudo descargar \"$fileName\": $error\n\nCompruebe el espacio en disco local y los permisos.';
  }

  @override
  String get sftpErrorDirNameEmpty =>
      'El nombre del directorio no puede estar vacío.';

  @override
  String get sftpErrorDirNameSeparators =>
      'El nombre del directorio no puede contener separadores de ruta (/ o \\).';

  @override
  String get sftpErrorDirNameParentRef =>
      'El nombre del directorio no puede contener \"..\" (referencias al directorio superior).';

  @override
  String get sftpErrorDirNameTooLong =>
      'El nombre del directorio es demasiado largo (máximo 255 caracteres).';

  @override
  String get sftpCreatingDirectory => 'Creando directorio…';

  @override
  String sftpErrorCreateDirectory(String dirName, String error) {
    return 'No se pudo crear el directorio \"$dirName\": $error\n\nCompruebe los permisos remotos.';
  }

  @override
  String sftpDeletingFile(String fileName) {
    return 'Eliminando $fileName…';
  }

  @override
  String sftpErrorDeleteFile(String fileName, String error) {
    return 'No se pudo eliminar \"$fileName\": $error\n\nCompruebe los permisos remotos y que no esté en uso.';
  }

  @override
  String get sftpLoadingPreview => 'Cargando vista previa…';

  @override
  String sftpErrorLoadPreview(String error) {
    return 'No se pudo cargar la vista previa: $error';
  }

  @override
  String sftpFileBrowserTitle(String instanceName) {
    return 'Explorador de archivos - $instanceName';
  }

  @override
  String get sftpSearchHint => 'Buscar archivos y carpetas…';

  @override
  String get sftpParentDirectoryTooltip => 'Ir al directorio superior';

  @override
  String get sftpUploadButton => 'Subir';

  @override
  String get sftpUploadFileButton => 'Subir archivo';

  @override
  String get sftpUploadFolderButton => 'Subir carpeta';

  @override
  String get sftpNewFolderButton => 'Nueva carpeta';

  @override
  String get sftpDropFilesHere => 'Suelte los archivos aquí para subirlos';

  @override
  String get sftpEmptyFolder =>
      'Esta carpeta está vacía\n\nArrastre y suelte archivos aquí para subirlos';

  @override
  String sftpNoFilesMatch(String query) {
    return 'Ningún archivo coincide con \"$query\"';
  }

  @override
  String get sftpCreateFolderTitle => 'Crear nueva carpeta';

  @override
  String get sftpFolderNameLabel => 'Nombre de la carpeta';

  @override
  String get sftpCreateButton => 'Crear';

  @override
  String get sftpConfirmDeleteTitle => 'Confirmar eliminación';

  @override
  String sftpConfirmDeleteMessage(String fileName) {
    return '¿Confirma que desea eliminar \"$fileName\"?';
  }

  @override
  String get sftpFolderLabel => 'Carpeta';

  @override
  String get sftpPreviewTooltip => 'Vista previa';

  @override
  String get sftpDownloadTooltip => 'Descargar';

  @override
  String sftpErrorLoadFile(String error) {
    return 'No se pudo cargar el archivo: $error';
  }

  @override
  String get sftpErrorLoadImage => 'No se pudo cargar la imagen';

  @override
  String get dashboardLoadingAccountsTooltip => 'Cargando cuentas…';

  @override
  String get appLogoutButton => 'Cerrar sesión';

  @override
  String get appConnectionHistoryTitle => 'Historial de conexiones';

  @override
  String get appExportLogsTooltip => 'Exportar registros';

  @override
  String get appAboutTooltip => 'Acerca de';

  @override
  String get dashboardGcloudRequiredTitle => 'Se requiere Google Cloud CLI';

  @override
  String get dashboardGcloudRequiredDescription =>
      'Lightweight Cloud Connector requiere Google Cloud CLI (gcloud) para conectarse a los recursos de GCP.';

  @override
  String get dashboardInstallInstructionsTitle =>
      'Instrucciones de instalación';

  @override
  String get dashboardInstallInstructionsBody =>
      'Vaya al siguiente sitio y siga las instrucciones para instalar Google Cloud SDK para el sistema operativo correspondiente:';

  @override
  String get dashboardOpenInstructionsButton =>
      'Abrir instrucciones en el navegador';

  @override
  String get dashboardCheckAgainButton => 'Comprobar de nuevo';

  @override
  String get dashboardLaunchingBrowserLogin =>
      'Abriendo el navegador para iniciar sesión…';

  @override
  String dashboardLoginFailed(String error) {
    return 'Error al iniciar sesión: $error';
  }

  @override
  String get dashboardLoginButton => 'Iniciar sesión en Google Cloud';

  @override
  String get appExportingLogs => 'Exportando registros…';

  @override
  String get appLogsExportedTitle => 'Registros exportados correctamente';

  @override
  String get appLogsExportedBody =>
      'Todos los registros se han consolidado y exportado a:';

  @override
  String get appLogsExportedHint =>
      'Este archivo se puede compartir para tareas de resolución de problemas.';

  @override
  String appExportLogsFailed(String error) {
    return 'Error al exportar registros: $error';
  }

  @override
  String appLogoutMultiAccountCount(int count) {
    return 'Hay $count cuentas autenticadas.';
  }

  @override
  String appLogoutActiveAccount(String email) {
    return 'Activa: $email';
  }

  @override
  String appLogoutThisAccount(String email) {
    return 'Cerrar sesión de $email';
  }

  @override
  String get appLogoutAllAccounts => 'Cerrar sesión de todas';

  @override
  String get appLogoutConfirmSingle =>
      'Esto revocará las credenciales de Google Cloud en este equipo. ¿Confirma que desea continuar?';

  @override
  String appLoggedOutAccount(String email) {
    return 'Sesión cerrada para $email.';
  }

  @override
  String appLogoutError(String error) {
    return 'Error al cerrar sesión: $error';
  }

  @override
  String get appLoggedOutFullMessage =>
      'Sesión cerrada correctamente. Se borraron todos los datos en caché.';

  @override
  String dashboardAutoRefreshEnabledTooltip(int seconds) {
    return 'Actualización automática activada (${seconds}s)';
  }

  @override
  String get dashboardEnableAutoRefreshTooltip =>
      'Habilitar actualización automática';

  @override
  String get dashboardAutoRefreshDisabledSnackbar =>
      'Actualización automática desactivada';

  @override
  String dashboardAutoRefreshEnabledSnackbar(int seconds) {
    return 'Actualización automática activada (intervalo de ${seconds}s)';
  }

  @override
  String appAddedInstanceSnackbar(String name) {
    return 'Instancia añadida: $name';
  }

  @override
  String get appCopyright => '© 2026 Jordi Lopez Reyes';

  @override
  String get appTagline =>
      'Una herramienta nativa para simplificar las conexiones IAP de Google Cloud en Linux.';

  @override
  String get appEditionsCalverTitle => 'Ediciones de LCC — CalVer';

  @override
  String get appEditionsCalverBody =>
      'Las ediciones siguen un ciclo semestral (AAHn):\n  • 26H1 — Primer semestre de 2026\n  • 26H2 — Segundo semestre de 2026 (actual)\nLas compilaciones aportan correcciones continuas entre ediciones.';

  @override
  String appWhatsNewTitle(String edition) {
    return 'Novedades de la edición $edition:';
  }

  @override
  String get appWhatsNewItem1 =>
      '• Visualización de etiquetas de VM y búsqueda por etiquetas';

  @override
  String get appWhatsNewItem2 => '• Estado de VM Suspender/Reanudar';

  @override
  String get appWhatsNewItem3 =>
      '• OS Login y detección automática de VM Windows';

  @override
  String get appWhatsNewItem4 =>
      '• Gestor global de túneles + reconexión automática';

  @override
  String get appWhatsNewItem5 => '• Multicuenta y explorador de proyectos';

  @override
  String get appWhatsNewItem6 =>
      '• Diagnóstico de conectividad (10 comprobaciones)';

  @override
  String get appWhatsNewItem7 =>
      '• Montaje SSHFS, clientes de bases de datos, credenciales de Windows';

  @override
  String get appDeveloperLabel => 'Desarrollador:';

  @override
  String get appSourceCodeLabel => 'Código fuente:';

  @override
  String get appTechStackLabel => 'Tecnologías:';

  @override
  String get appTechStackValue =>
      'Flutter • Rust • Google Cloud Client Libraries';

  @override
  String get dashboardSearchInstancesHint => 'Buscar instancias…';

  @override
  String get dashboardFilterAll => 'Todas';

  @override
  String get dashboardAllProjectsHint => 'Todos los proyectos';

  @override
  String get dashboardNoProjectsSelected => 'No hay proyectos seleccionados';

  @override
  String get dashboardSelectProjectsHint =>
      'Pulse \"Seleccionar proyectos\" arriba para elegir proyectos de GCP';

  @override
  String get dashboardProjectsErrorsTitle =>
      'Algunos proyectos tuvieron errores';

  @override
  String get dashboardPermissionDeniedParen => '(Permiso denegado)';

  @override
  String get dashboardErrorParen => '(Error)';

  @override
  String get dashboardNoInstancesFoundProjects =>
      'No se encontraron instancias en los proyectos seleccionados.';

  @override
  String get dashboardNoMatchingInstances => 'No hay instancias coincidentes.';

  @override
  String dashboardFavoritesCount(int count) {
    return 'Favoritos ($count)';
  }

  @override
  String get dashboardRemoveFavoriteTooltip => 'Quitar de favoritos';

  @override
  String get dashboardAddFavoriteTooltip => 'Añadir a favoritos';

  @override
  String get dashboardPermissionDenied => 'Permiso denegado';

  @override
  String get dashboardErrorLoadingShort => 'Error al cargar';

  @override
  String dashboardRunningTunnelActive(String machineType) {
    return 'RUNNING • Túnel activo • $machineType';
  }

  @override
  String get dashboardMenuMountSshfs => 'Montar SSHFS';

  @override
  String get dashboardMenuStop => 'Detener';

  @override
  String get dashboardMenuStart => 'Iniciar';

  @override
  String get dashboardMenuSuspend => 'Suspender';

  @override
  String get dashboardMenuReset => 'Reiniciar';

  @override
  String get dashboardMenuResume => 'Reanudar';

  @override
  String get dashboardMenuDoctor => 'Doctor';

  @override
  String get dashboardOpeningSftp => 'Abriendo SFTP…';

  @override
  String get dashboardOpeningSshfsMount => 'Abriendo montaje SSHFS…';

  @override
  String get dashboardStartingInstanceShort => 'Iniciando instancia…';

  @override
  String get dashboardStoppingInstanceShort => 'Deteniendo instancia…';

  @override
  String get dashboardSuspendingInstanceShort => 'Suspendiendo instancia…';

  @override
  String get dashboardResumingInstanceShort => 'Reanudando instancia…';

  @override
  String get dashboardResettingInstanceShort => 'Reiniciando instancia…';

  @override
  String get dashboardSelectInstanceHint =>
      'Seleccione una instancia para ver los detalles';

  @override
  String get dashboardInstanceResourcesTitle => 'Recursos de la instancia';

  @override
  String get dashboardCpuLabel => 'CPU';

  @override
  String dashboardVcpusValue(int count) {
    return '$count vCPU';
  }

  @override
  String get dashboardRamLabel => 'RAM';

  @override
  String dashboardSizeGbValue(String size) {
    return '$size GB';
  }

  @override
  String get dashboardDiskLabel => 'Disco';

  @override
  String get dashboardOsLoginChip => 'OS Login';

  @override
  String get dashboardActiveTunnelsTitle => 'Túneles activos';

  @override
  String get dashboardActionsTitle => 'Acciones';

  @override
  String get dashboardConnectRdpButton => 'Conectar RDP';

  @override
  String get dashboardConnectVncButton => 'Conectar VNC';

  @override
  String get dashboardConnectSshButton => 'Conectar SSH';

  @override
  String get dashboardLaunchingTerminal => 'Abriendo terminal…';

  @override
  String dashboardSshError(String error) {
    return 'Error de SSH: $error';
  }

  @override
  String get dashboardOpenSftpButton => 'Abrir SFTP';

  @override
  String get dashboardOpeningTunnelSftp => 'Abriendo túnel para SFTP…';

  @override
  String get dashboardSftpTunnelFailed =>
      'No se pudo crear el túnel SSH para SFTP.\n\nCompruebe lo siguiente:\n• La instancia está en RUNNING\n• Dispone de permisos de túnel IAP\n• La conectividad de red funciona correctamente\n• gcloud CLI está autenticado';

  @override
  String dashboardStateError(String error) {
    return 'Error de estado: $error\nReinicie la aplicación.';
  }

  @override
  String dashboardSftpBrowserFailed(String error) {
    return 'No se pudo abrir el explorador SFTP: $error';
  }

  @override
  String get dashboardUnexpectedError =>
      'Se produjo un error inesperado.\nRevise los registros de la consola y reporte este problema.';

  @override
  String get dashboardCustomTunnelButton => 'Túnel personalizado';

  @override
  String get dashboardDatabaseButton => 'Base de datos';

  @override
  String get dashboardCreatingSshTunnelSshfs =>
      'Creando túnel SSH para el montaje SSHFS…';

  @override
  String get dashboardSshfsTunnelFailed =>
      'No se pudo crear el túnel SSH para el montaje SSHFS.';

  @override
  String get dashboardDisconnectAllTunnelsButton =>
      'Desconectar todos los túneles';

  @override
  String get dashboardTestIapConnectionButton => 'Probar conexión IAP';

  @override
  String get dashboardTestingIapConnection =>
      'Probando la conexión IAP… Esto verifica que IAP esté correctamente configurado.';

  @override
  String get dashboardStartInstanceButton => 'Iniciar instancia';

  @override
  String get dashboardStartingInstanceProgress =>
      'Iniciando instancia… Esto puede tardar unos minutos.';

  @override
  String dashboardStartInstanceFailed(String error) {
    return 'Error al iniciar la instancia: $error';
  }

  @override
  String get dashboardStopInstanceButton => 'Detener instancia';

  @override
  String dashboardStopInstanceConfirm(String name) {
    return '¿Confirma que desea detener $name?\n\nEsto desconectará todos los túneles activos y apagará la instancia.';
  }

  @override
  String get dashboardStoppingInstanceProgress =>
      'Deteniendo instancia… Esto puede tardar unos minutos.';

  @override
  String dashboardStopInstanceFailed(String error) {
    return 'Error al detener la instancia: $error';
  }

  @override
  String get dashboardResetInstanceButton => 'Reiniciar instancia';

  @override
  String dashboardResetInstanceConfirm(String name) {
    return '¿Confirma que desea reiniciar $name?\n\nEsto forzará el reinicio de la instancia y desconectará todos los túneles activos.';
  }

  @override
  String get dashboardResettingInstanceProgress =>
      'Reiniciando instancia… Esto puede tardar unos minutos.';

  @override
  String dashboardResetInstanceFailed(String error) {
    return 'Error al reiniciar la instancia: $error';
  }

  @override
  String get dashboardSuspendInstanceButton => 'Suspender instancia';

  @override
  String dashboardSuspendInstanceConfirm(String name) {
    return '¿Confirma que desea suspender $name?\n\nEsto guardará el estado de la VM en disco y desconectará todos los túneles activos. Podrá reanudarla más tarde.';
  }

  @override
  String get dashboardSuspendingInstanceProgress =>
      'Suspendiendo instancia… Esto puede tardar unos minutos.';

  @override
  String get dashboardInstanceSuspendedSuccess =>
      '¡Instancia suspendida correctamente!';

  @override
  String dashboardSuspendInstanceFailed(String error) {
    return 'Error al suspender la instancia: $error';
  }

  @override
  String get dashboardResumeInstanceButton => 'Reanudar instancia';

  @override
  String get dashboardResumingInstanceProgress =>
      'Reanudando instancia… Esto puede tardar unos minutos.';

  @override
  String get dashboardInstanceResumedSuccess =>
      '¡Instancia reanudada correctamente!';

  @override
  String dashboardResumeInstanceFailed(String error) {
    return 'Error al reanudar la instancia: $error';
  }

  @override
  String get appCustomTunnelTitle => 'Configuración de túnel personalizado';

  @override
  String get appCustomTunnelDescription =>
      'Seleccione un servicio predefinido o introduzca un puerto personalizado:';

  @override
  String get appCustomPortLabel => 'Puerto personalizado';

  @override
  String get appCustomPortHint => 'Introduzca el puerto (1-65535)';

  @override
  String appSelectedPortLabel(int port) {
    return 'Puerto seleccionado: $port';
  }

  @override
  String get appConnectionSettingsTitle => 'Configuración de conexión';

  @override
  String get appDomainOptionalLabel => 'Dominio (opcional)';

  @override
  String get appSaveCredentialsLabel => 'Guardar credenciales';

  @override
  String get appFullscreenLabel => 'Pantalla completa';

  @override
  String get appWidthLabel => 'Ancho';

  @override
  String get appHeightLabel => 'Alto';

  @override
  String get appVncConnectionSettingsTitle => 'Configuración de conexión VNC';

  @override
  String get appPasswordOptionalLabel => 'Contraseña (opcional)';

  @override
  String get appVncPasswordHelper =>
      'Déjelo vacío si el servidor VNC no tiene contraseña';

  @override
  String get appDisplayOptionsLabel => 'Opciones de pantalla';

  @override
  String get appViewOnlyLabel => 'Solo visualización';

  @override
  String get appViewOnlyHelper =>
      'Modo de solo lectura (sin entrada de teclado ni ratón)';

  @override
  String get appQualityLabel => 'Calidad';

  @override
  String get appConnectionQualityLabel => 'Calidad de conexión';

  @override
  String get appQualityAuto => 'Automática (recomendado)';

  @override
  String get appQualityHigh => 'Alta calidad';

  @override
  String get appQualityMedium => 'Calidad media';

  @override
  String get appQualityLow => 'Baja calidad (más rápido)';

  @override
  String get dashboardTunnelUnhealthy => 'No saludable';

  @override
  String get dashboardTunnelDegraded => 'Degradado';

  @override
  String dashboardTunnelPortLabel(String port) {
    return 'Túnel → :$port';
  }

  @override
  String get dashboardDisconnectTunnelTooltip => 'Desconectar este túnel';

  @override
  String get dashboardUptimeLabel => 'Tiempo activo';

  @override
  String get dashboardLastCheckLabel => 'Última comprobación';

  @override
  String get dashboardLatencyLabel => 'Latencia';

  @override
  String dashboardAttemptLabel(int current, int max) {
    return 'Intento $current/$max';
  }

  @override
  String get dashboardRetryConnectionButton => 'Reintentar conexión';

  @override
  String get dashboardOnState => 'ON';

  @override
  String get dashboardOffState => 'OFF';

  @override
  String dashboardAutoMonitoringLabel(String state) {
    return 'Supervisión automática cada 30s | Reconexión automática: $state';
  }

  @override
  String get appNoProjectsFound => 'No se encontraron proyectos.';

  @override
  String get appSelectProjectLabel => 'Seleccionar proyecto';

  @override
  String appErrorLoadingProjects(String error) {
    return 'Error al cargar proyectos: $error';
  }

  @override
  String get appSelectProjectsButton => 'Seleccionar proyectos';

  @override
  String appProjectsSelectedCount(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count proyectos',
      one: '$count proyecto',
    );
    return '$_temp0 ($total VM)';
  }

  @override
  String appProjectsErrorsTooltip(int count) {
    return '$count proyecto(s) con errores';
  }

  @override
  String get appManageProjectsTitle => 'Administrar proyectos';

  @override
  String get appRefreshAllProjectsTooltip => 'Actualizar todos los proyectos';

  @override
  String get appSearchProjectsHint => 'Buscar proyectos…';

  @override
  String appProjectsSelectedOfMax(int count, int max) {
    return '$count de $max proyectos seleccionados';
  }

  @override
  String appTotalVmsLabel(int total) {
    return '$total VM en total';
  }

  @override
  String get appNoProjectsAvailable => 'No hay proyectos disponibles';

  @override
  String get appNoMatchingProjects => 'No hay proyectos coincidentes';

  @override
  String appInstanceCountVms(int count) {
    return '$count VM';
  }

  @override
  String get appClearAllButton => 'Borrar todo';

  @override
  String get appDoneButton => 'Hecho';

  @override
  String get appClearButton => 'Borrar';

  @override
  String get appClearHistoryTitle => 'Borrar historial';

  @override
  String get appClearHistoryConfirm =>
      '¿Confirma que desea borrar todo el historial de conexiones?';

  @override
  String get appNoConnectionHistory => 'Sin historial de conexiones';

  @override
  String get appNoConnectionHistoryHint =>
      'Las conexiones recientes aparecerán aquí';

  @override
  String get appConnectAgainTooltip => 'Conectar de nuevo';

  @override
  String get appVmNotFoundTooltip =>
      'VM no encontrada en los proyectos actuales';

  @override
  String get appJustNow => 'Ahora mismo';

  @override
  String appMinutesAgo(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String appHoursAgo(int hours) {
    return 'hace $hours h';
  }

  @override
  String appDaysAgo(int days) {
    return 'hace $days d';
  }

  @override
  String get tunnelErrorNotAuthenticated =>
      'No hay sesión iniciada en Google Cloud. Ejecute \'gcloud auth login\'.';

  @override
  String get tunnelErrorPermissionDenied =>
      'Permiso denegado. La cuenta necesita el rol de usuario de túnel protegido por IAP.';

  @override
  String get tunnelErrorInstanceNotFound =>
      'La instancia ya no existe en este proyecto y zona.';

  @override
  String get tunnelErrorInstanceNotRunning =>
      'La instancia no está en ejecución.';

  @override
  String get tunnelErrorFirewallBlocked =>
      'Una regla de firewall está bloqueando IAP. Permita el tráfico de entrada desde 35.235.240.0/20.';

  @override
  String get tunnelErrorRelayUnreachable =>
      'No se pudo contactar con el relay de IAP. Compruebe la red o la configuración del proxy.';

  @override
  String get tunnelErrorProtocolError =>
      'Respuesta inesperada del relay de IAP.';

  @override
  String get tunnelErrorLocalPortUnavailable =>
      'No hay ningún puerto local disponible para el túnel.';

  @override
  String get tunnelErrorUnknown => 'No se pudo establecer el túnel.';
}
