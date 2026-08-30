const API_PATH = "/usr/share/cockpit/backups/backup_api.py";
let currentProto = "cifs";

function runApi(args) {
    return cockpit.spawn(["python3", API_PATH, ...args], { superuser: "try" })
        .then(out => JSON.parse(out.trim()))
        .catch(err => ({ status: "error", message: err.message || String(err) }));
}

function switchTab(paneId, btnId) {
    document.querySelectorAll('.tab-pane').forEach(el => el.style.display = 'none');
    document.querySelectorAll('.ct-tab-item').forEach(el => el.classList.remove('active'));
    
    const targetPane = document.getElementById(paneId);
    const targetBtn = document.getElementById(btnId);
    if (targetPane) targetPane.style.display = 'block';
    if (targetBtn) targetBtn.classList.add('active');

    if (paneId === 'tab-tasks') cargarTareas();
}

function selectProto(proto) {
    currentProto = proto;
    document.querySelectorAll('.proto-box').forEach(el => el.classList.remove('selected'));
    
    const targetCard = document.getElementById('card-' + proto);
    if (targetCard) targetCard.classList.add('selected');

    document.querySelectorAll('.field-cifs, .field-ssh, .field-local, .field-remote').forEach(el => el.style.display = 'none');

    if (proto === 'cifs') {
        document.querySelectorAll('.field-cifs, .field-remote').forEach(el => el.style.display = 'flex');
    } else if (proto === 'ssh') {
        document.querySelectorAll('.field-ssh, .field-remote').forEach(el => el.style.display = 'flex');
    } else {
        document.querySelectorAll('.field-local').forEach(el => el.style.display = 'flex');
    }
}

function cargarTareas() {
    const tbody = document.getElementById('tasks-table-body');
    const selectLog = document.getElementById('log-task-select');
    if (!tbody) return;

    tbody.innerHTML = '<tr><td colspan="9" style="text-align: center; color: var(--font); padding: 25px;"><i class="fas fa-spinner fa-spin"></i> Cargando tareas de respaldo...</td></tr>';

    runApi(["list"]).then(res => {
        if (res.status !== "ok" || !res.tasks || res.tasks.length === 0) {
            tbody.innerHTML = '<tr><td colspan="9" style="text-align: center; color: var(--font); opacity: 0.7; padding: 35px;">No hay tareas de backup programadas actualmente. Haz clic en "Nueva Tarea" para crear una.</td></tr>';
            if (selectLog) selectLog.innerHTML = '<option value="">(Sin tareas registradas)</option>';
            return;
        }

        tbody.innerHTML = '';
        if (selectLog) selectLog.innerHTML = '';

        res.tasks.forEach(t => {
            if (selectLog) {
                const opt = document.createElement('option');
                opt.value = t.id;
                opt.textContent = `${t.id} (${t.proto})`;
                selectLog.appendChild(opt);
            }

            const tr = document.createElement('tr');
            
            let statusBadge = `<span class="badge badge-pending"><i class="fas fa-clock"></i> ${t.last_status}</span>`;
            if (t.last_status === 'Éxito') {
                statusBadge = `<span class="badge badge-success"><i class="fas fa-check-circle"></i> Éxito</span>`;
            } else if (t.last_status === 'Fallo') {
                statusBadge = `<span class="badge badge-danger"><i class="fas fa-times-circle"></i> Fallo</span>`;
            }

            tr.innerHTML = `
                <td><strong>${t.id}</strong></td>
                <td><span class="badge badge-proto">${t.proto}</span></td>
                <td><code style="color: #58a6ff;">${t.src}</code></td>
                <td><code>${t.cron}</code></td>
                <td>${t.retention} snaps</td>
                <td><strong>${t.snaps}</strong> en disco</td>
                <td>${t.last_run}</td>
                <td>${statusBadge}</td>
                <td style="text-align: right; white-space: nowrap;">
                    <button class="pf-c-button pf-m-secondary btn-exec" data-id="${t.id}" title="Ejecutar Backup Inmediatamente"><i class="fas fa-bolt"></i> Ejecutar</button>
                    <button class="pf-c-button pf-m-secondary btn-logs" data-id="${t.id}" title="Ver Historial de Logs"><i class="fas fa-file-alt"></i> Logs</button>
                    <button class="pf-c-button pf-m-danger btn-del" data-id="${t.id}" title="Eliminar Tarea"><i class="fas fa-trash-alt"></i></button>
                </td>
            `;

            // Attach event listeners
            tr.querySelector('.btn-exec').addEventListener('click', () => ejecutarAhora(t.id));
            tr.querySelector('.btn-logs').addEventListener('click', () => abrirModalLogs(t.id));
            tr.querySelector('.btn-del').addEventListener('click', () => eliminarTarea(t.id));

            tbody.appendChild(tr);
        });
    });
}

function probarConexion() {
    const alertBox = document.getElementById('alert-test');
    alertBox.style.display = 'block';
    alertBox.className = 'alert alert-info';
    alertBox.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Probando conexión con el servidor remoto...';

    const payload = {
        ip: document.getElementById('task-ip').value.trim(),
        user: document.getElementById('task-user').value.trim(),
        password: document.getElementById('task-password').value
    };

    let action = "test_cifs";
    if (currentProto === "cifs") {
        payload.share = document.getElementById('task-share').value.trim();
    } else if (currentProto === "ssh") {
        action = "test_ssh";
        payload.port = document.getElementById('task-port').value.trim();
    }

    runApi([action, JSON.stringify(payload)]).then(res => {
        if (res.status === "ok") {
            alertBox.className = 'alert alert-success';
            alertBox.innerHTML = '<i class="fas fa-check-circle"></i> ' + res.message;
        } else {
            alertBox.className = 'alert alert-danger';
            alertBox.innerHTML = '<i class="fas fa-exclamation-triangle"></i> ' + res.message;
        }
    });
}

function guardarTarea() {
    const tid = document.getElementById('task-id').value.trim();
    if (!tid) { alert('Por favor ingresa un identificador para la tarea.'); return; }

    const cronSelect = document.getElementById('task-cron-select').value;
    const cronExpr = (cronSelect === 'custom') ? document.getElementById('task-cron').value.trim() : cronSelect;

    const payload = {
        id: tid,
        proto: currentProto,
        cron: cronExpr,
        retention: parseInt(document.getElementById('task-retention').value) || 30
    };

    if (currentProto === 'cifs') {
        payload.ip = document.getElementById('task-ip').value.trim();
        payload.share = document.getElementById('task-share').value.trim();
        payload.user = document.getElementById('task-user').value.trim();
        payload.password = document.getElementById('task-password').value;
    } else if (currentProto === 'ssh') {
        payload.ip = document.getElementById('task-ip').value.trim();
        payload.port = document.getElementById('task-port').value.trim();
        payload.path = document.getElementById('task-remote-path').value.trim();
        payload.user = document.getElementById('task-user').value.trim();
        payload.password = document.getElementById('task-password').value;
    } else {
        payload.path = document.getElementById('task-local-path').value.trim();
    }

    const btnSave = document.getElementById('btn-save');
    btnSave.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Guardando...';

    runApi(["create", JSON.stringify(payload)]).then(res => {
        btnSave.innerHTML = '<i class="fas fa-save"></i> Guardar y Programar Tarea';
        if (res.status === "ok") {
            alert('✔ ' + res.message);
            switchTab('tab-tasks', 'tab-btn-tasks');
        } else {
            alert('✕ Error: ' + res.message);
        }
    });
}

function ejecutarAhora(taskId) {
    if (!confirm(`¿Deseas iniciar la ejecución del respaldo de la tarea [${taskId}] ahora mismo en segundo plano?`)) return;
    cockpit.spawn(["bash", `/usr/local/bin/backup_${taskId}.sh`], { superuser: "try" })
        .then(() => {
            alert(`✔ Tarea [${taskId}] finalizada exitosamente.`);
            cargarTareas();
        })
        .catch(err => {
            alert(`✕ Error al ejecutar [${taskId}]: ${err.message || err}`);
            cargarTareas();
        });
    alert(`⚡ Backup [${taskId}] iniciado en segundo plano. Puedes consultar el progreso en los logs.`);
    cargarTareas();
}

function eliminarTarea(taskId) {
    if (!confirm(`¿Estás seguro de eliminar la tarea programada [${taskId}] y sus credenciales? (Los respaldos históricos en disco no se borrarán).`)) return;
    runApi(["delete", taskId]).then(res => {
        alert(res.message);
        cargarTareas();
    });
}

function abrirModalLogs(taskId) {
    document.getElementById('modal-log-title').textContent = `Registro de Actividad: ${taskId}`;
    document.getElementById('modal-logs').style.display = 'flex';
    document.getElementById('modal-log-console').textContent = 'Cargando logs...';
    runApi(["logs", taskId]).then(res => {
        document.getElementById('modal-log-console').textContent = res.logs || '(Sin registros)';
    });
}

function verLogs(taskId) {
    if (!taskId) return;
    document.getElementById('log-console').textContent = 'Cargando...';
    runApi(["logs", taskId]).then(res => {
        document.getElementById('log-console').textContent = res.logs || '(Sin registros)';
    });
}

function cerrarModal() {
    document.getElementById('modal-logs').style.display = 'none';
}

// Attach all DOM Event Listeners
document.addEventListener('DOMContentLoaded', () => {
    // Theme setup from Cockpit / Houston
    const theme = localStorage.getItem('houston-theme') || 'dark';
    document.documentElement.setAttribute('data-theme', theme);

    // Tab buttons
    document.getElementById('tab-btn-tasks').addEventListener('click', () => switchTab('tab-tasks', 'tab-btn-tasks'));
    document.getElementById('tab-btn-new').addEventListener('click', () => switchTab('tab-new', 'tab-btn-new'));
    document.getElementById('tab-btn-logs').addEventListener('click', () => switchTab('tab-logs', 'tab-btn-logs'));

    // Top action buttons
    document.getElementById('btn-refresh').addEventListener('click', cargarTareas);
    document.getElementById('btn-new-task-top').addEventListener('click', () => switchTab('tab-new', 'tab-btn-new'));

    // Protocol card buttons
    document.getElementById('card-cifs').addEventListener('click', () => selectProto('cifs'));
    document.getElementById('card-ssh').addEventListener('click', () => selectProto('ssh'));
    document.getElementById('card-local').addEventListener('click', () => selectProto('local'));

    // Cron dropdown
    document.getElementById('task-cron-select').addEventListener('change', (e) => {
        document.getElementById('group-custom-cron').style.display = (e.target.value === 'custom') ? 'flex' : 'none';
    });

    // Form buttons
    document.getElementById('btn-test').addEventListener('click', probarConexion);
    document.getElementById('btn-save').addEventListener('click', guardarTarea);

    // Logs refresh
    document.getElementById('btn-refresh-logs').addEventListener('click', () => {
        verLogs(document.getElementById('log-task-select').value);
    });
    document.getElementById('log-task-select').addEventListener('change', (e) => {
        verLogs(e.target.value);
    });

    // Modal close
    document.getElementById('btn-close-modal').addEventListener('click', cerrarModal);
    document.getElementById('btn-modal-x').addEventListener('click', cerrarModal);

    // Initial load
    cargarTareas();
});
