# -*- coding: utf-8 -*-
"""Genera la guía rápida de instalación en PDF a partir del contenido del README."""
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import (
    KeepTogether, ListFlowable, ListItem, PageBreak, Paragraph,
    SimpleDocTemplate, Spacer, Table, TableStyle, XPreformatted,
)

OUT = r"C:\Users\cflores\qa-mysql-setup\Guia-instalacion-QA.pdf"

ACCENT = colors.HexColor("#15605C")
ACCENT_SOFT = colors.HexColor("#E6F0EF")
INK = colors.HexColor("#1F2328")
MUTED = colors.HexColor("#5A6670")
CODE_BG = colors.HexColor("#F4F6F7")
RULE = colors.HexColor("#D5DBDF")
WARN_BG = colors.HexColor("#FFF6E5")
WARN_RULE = colors.HexColor("#E0A030")

ss = getSampleStyleSheet()

H_TITLE = ParagraphStyle("HTitle", parent=ss["Title"], fontName="Helvetica-Bold",
                         fontSize=21, leading=25, textColor=ACCENT, alignment=TA_LEFT,
                         spaceAfter=2)
H_SUB = ParagraphStyle("HSub", parent=ss["Normal"], fontName="Helvetica",
                       fontSize=10.5, leading=14, textColor=MUTED, spaceAfter=14)
H1 = ParagraphStyle("H1", parent=ss["Normal"], fontName="Helvetica-Bold",
                    fontSize=13, leading=16, textColor=ACCENT, spaceBefore=12, spaceAfter=6)
BODY = ParagraphStyle("Body", parent=ss["Normal"], fontName="Helvetica",
                      fontSize=9.8, leading=14, textColor=INK, spaceAfter=6)
SMALL = ParagraphStyle("Small", parent=BODY, fontSize=8.8, leading=12.5, textColor=MUTED)
# leftIndent/firstLineIndent heredados de ss["Code"] desalinean la primera linea
CODE = ParagraphStyle("Code", parent=ss["Code"], fontName="Courier",
                      fontSize=8.6, leading=12, textColor=colors.HexColor("#102A28"),
                      leftIndent=0, firstLineIndent=0, spaceBefore=0, spaceAfter=0)
CELL = ParagraphStyle("Cell", parent=BODY, fontSize=8.8, leading=12, spaceAfter=0)
CELL_H = ParagraphStyle("CellH", parent=CELL, fontName="Helvetica-Bold",
                        textColor=colors.white)
CELL_C = ParagraphStyle("CellC", parent=CELL, fontName="Courier", fontSize=8.2, leading=11.5)


def code(text, where=None):
    """Bloque de comandos con fondo y barra de color a la izquierda."""
    rows, style = [], [
        ("BACKGROUND", (0, 0), (-1, -1), CODE_BG),
        ("LINEBEFORE", (0, 0), (0, -1), 2.2, ACCENT),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]
    if where:
        rows.append([Paragraph(where, ParagraphStyle(
            "Where", parent=SMALL, fontName="Helvetica-Bold", fontSize=7.6,
            textColor=ACCENT, spaceAfter=0))])
        style += [("BOTTOMPADDING", (0, 0), (0, 0), 1)]
    rows.append([XPreformatted(text, CODE)])
    if where:
        style += [("TOPPADDING", (0, 1), (0, 1), 0)]
    t = Table(rows, colWidths=[16.0 * cm])
    t.setStyle(TableStyle(style))
    return t


def note(text, warn=False):
    t = Table([[Paragraph(text, SMALL)]], colWidths=[16.0 * cm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), WARN_BG if warn else ACCENT_SOFT),
        ("LINEBEFORE", (0, 0), (0, -1), 2.2, WARN_RULE if warn else ACCENT),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def step(n, title):
    t = Table([[Paragraph(str(n), ParagraphStyle(
                   "Num", parent=BODY, fontName="Helvetica-Bold", fontSize=12,
                   textColor=colors.white, alignment=1, spaceAfter=0)),
                Paragraph(title, ParagraphStyle(
                   "StepT", parent=H1, spaceBefore=0, spaceAfter=0, fontSize=12.5))]],
              colWidths=[0.78 * cm, 15.2 * cm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (0, 0), ACCENT),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (0, 0), 0),
        ("RIGHTPADDING", (0, 0), (0, 0), 0),
        ("LEFTPADDING", (1, 0), (1, 0), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LINEBELOW", (1, 0), (1, 0), 0.6, RULE),
    ]))
    return t


def bullets(items):
    # 'value' es para listas numeradas: puesto aqui imprime la palabra literal
    return ListFlowable(
        [ListItem(Paragraph(i, BODY), leftIndent=14) for i in items],
        bulletType="bullet", start="•", bulletFontName="Helvetica",
        bulletFontSize=8, bulletColor=ACCENT, bulletOffsetY=-1,
        leftIndent=12, spaceBefore=2, spaceAfter=6)


def table2(header, rows, widths=(5.4 * cm, 10.6 * cm)):
    data = [[Paragraph(header[0], CELL_H), Paragraph(header[1], CELL_H)]]
    for a, b in rows:
        data.append([Paragraph(a, CELL_C), Paragraph(b, CELL)])
    t = Table(data, colWidths=list(widths), repeatRows=1)
    st = [
        ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.5, RULE),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]
    for i in range(1, len(data)):
        if i % 2 == 0:
            st.append(("BACKGROUND", (0, i), (-1, i), colors.HexColor("#FAFBFB")))
    t.setStyle(TableStyle(st))
    return t


def footer(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.5)
    canvas.line(2.5 * cm, 1.5 * cm, A4[0] - 2.5 * cm, 1.5 * cm)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(2.5 * cm, 1.1 * cm,
                      "MySQL + phpMyAdmin en QA   ·   Ubuntu Server 26.04")
    canvas.drawRightString(A4[0] - 2.5 * cm, 1.1 * cm, "Página %d" % doc.page)
    canvas.restoreState()


# Atajo para texto en monoespaciada dentro de un párrafo
def m(t, size=9):
    return "<font name='Courier' size='%s'>%s</font>" % (size, t)


S = []
S.append(Paragraph("Instalar MySQL + phpMyAdmin en el servidor de QA", H_TITLE))
S.append(Paragraph("Guía rápida   ·   Ubuntu Server 26.04   ·   3 scripts, unos 10 minutos",
                   H_SUB))

S.append(Paragraph(
    "Al terminar tendrás MySQL con una base cargada desde un dump y phpMyAdmin para "
    "navegarla desde tu navegador. <b>Nada queda expuesto a la red</b>: todo escucha solo "
    "en " + m("127.0.0.1") + " y se accede por un túnel SSH. Los tres scripts son "
    "re-ejecutables: si algo falla, los corres otra vez sin romper nada ni perder las "
    "passwords ya generadas.", BODY))

S.append(Paragraph("Antes de empezar", H1))
S.append(bullets([
    "Ubuntu Server 26.04 y un usuario con " + m("sudo") + ".",
    "<b>Sin MariaDB instalado.</b> El script se detiene si lo encuentra: instalar MySQL "
    "encima provoca conflictos.",
    "El puerto " + m("8080") + " libre, o elige otro con " + m("PMA_PORT") + ". Si en 8080 "
    "ya corre el Nginx de una instalación previa, lo reutiliza sin quejarse.",
    "Espacio en " + m("/var") + " de al menos 3 veces el tamaño del dump. Con un dump de "
    "2 GB, menos de 5 GB libres es arriesgado.",
    "El dump a mano, en " + m(".sql") + ", " + m(".gz") + ", " + m(".bz2") + " o " +
    m(".zst") + " (no hace falta descomprimirlo).",
]))

S.append(KeepTogether([
    step(1, "Copiar los scripts al servidor"),
    Spacer(1, 6),
    code("cd C:\\Users\\cflores\\qa-mysql-setup\n"
         "scp 01-install-mysql-pma.sh 02-import-dump.sh 03-verify.sh USUARIO@IP:~/",
         "En tu Windows (PowerShell)"),
]))

S.append(KeepTogether([
    step(2, "Instalar"),
    Spacer(1, 6),
    code("ssh USUARIO@IP\nsudo bash 01-install-mysql-pma.sh", "En el servidor"),
    Spacer(1, 6),
    Paragraph(
        "Instala y asegura MySQL, Nginx, PHP-FPM y phpMyAdmin, crea la base " + m("qa_db") +
        " y el usuario " + m("qa_user") + ", y genera las passwords. Tarda unos minutos y "
        "termina con un resumen.", BODY),
    code("DB_NAME=mi_base DB_USER=mi_user sudo -E bash 01-install-mysql-pma.sh",
         "Para usar otros nombres"),
    Spacer(1, 6),
    note("Las passwords quedan en " + m("/root/.qa-db-credentials") + " (solo root puede "
         "leerlo). Vélas con " + m("sudo cat /root/.qa-db-credentials") + ". No las vuelve a "
         "generar si re-ejecutas el script."),
]))

S.append(KeepTogether([
    step(3, "Subir el dump"),
    Spacer(1, 6),
    code("# rsync reanuda si se corta la conexion: mejor para archivos grandes\n"
         "rsync -avP C:\\ruta\\al\\dump.sql USUARIO@IP:~/\n\n"
         "# alternativa simple\n"
         "scp C:\\ruta\\al\\dump.sql USUARIO@IP:~/",
         "En tu Windows (PowerShell)"),
]))

S.append(KeepTogether([
    step(4, "Inspeccionar y cargar"),
    Spacer(1, 6),
    Paragraph("Primero mira el dump sin tocar nada. Te dice cuántas tablas trae, si trae su "
              "propia base, si hay " + m("DEFINER=") + ", triggers o fechas " +
              m("0000-00-00") + ":", BODY),
    code("DRY_RUN=1 sudo -E bash 02-import-dump.sh ~/dump.sql", "En el servidor"),
    Spacer(1, 6),
    Paragraph("Y luego cárgalo:", BODY),
    code("sudo bash 02-import-dump.sh ~/dump.sql", "En el servidor"),
    Spacer(1, 6),
    Paragraph("Pide confirmación escribiendo " + m("SI") + " si la base destino ya tiene "
              "tablas, y registra cada error en " + m("/var/log/qa-import-errors.log") +
              " sin abortar la carga.", BODY),
    note("Con un dump grande, lánzalo dentro de " + m("tmux") + " o " + m("screen") + ": así "
         "un corte de SSH no mata la importación a medio camino. Si falla por fechas " +
         m("0000-00-00") + " (típico de dumps de MySQL 5.7), repite con " +
         m("RELAX_SQLMODE=1 sudo -E bash 02-import-dump.sh ~/dump.sql") + ".", warn=True),
]))

S.append(KeepTogether([
    step(5, "Verificar"),
    Spacer(1, 6),
    code("sudo bash 03-verify.sh", "En el servidor"),
    Spacer(1, 6),
    Paragraph(
        "Solo lee, no modifica nada. Comprueba servicios activos y habilitados al arranque, "
        "que ni 3306 ni 8080 escuchen fuera de localhost, que no haya usuarios MySQL remotos "
        "ni anónimos, que phpMyAdmin responda 200, las credenciales de QA, el recuento de "
        "tablas y " + m("mysqlcheck") + ". <b>El objetivo es cerrar con 0 fallos.</b>", BODY),
    note("Si el dump viene de una producción que ya tiene las collations mezcladas, déjalas "
         "así: convertirlas haría que QA ordene y compare texto distinto que producción. "
         "Acepta ese hallazgo conocido con " +
         m("ALLOW_MIXED_COLLATION=1 sudo -E bash 03-verify.sh") + " para que no te deje un "
         "fallo fijo que acabes ignorando. El " + m("-E") + " de sudo es imprescindible: sin "
         "él, la variable no llega al script."),
]))

S.append(KeepTogether([
    step(6, "Entrar a phpMyAdmin"),
    Spacer(1, 6),
    Paragraph("Abre el túnel y <b>deja esa ventana abierta</b> mientras uses phpMyAdmin:", BODY),
    code("ssh -L 8080:127.0.0.1:8080 USUARIO@IP", "En tu Windows (PowerShell)"),
    Spacer(1, 6),
    Paragraph("Con el túnel vivo, en el navegador: <font name='Courier' size='10'><b>"
              "http://localhost:8080</b></font>", BODY),
    Paragraph("Entra con " + m("qa_user") + " y su password de " +
              m("/root/.qa-db-credentials") + ". El login como " + m("root") + " está "
              "bloqueado a propósito.", BODY),
]))

S.append(PageBreak())

S.append(Paragraph("Si algo sale mal", H1))
S.append(table2(
    ("Síntoma", "Causa y solución"),
    [
        ("El script termina sin mensaje tras 'nginx'",
         "Algo ya ocupa el puerto 80 (Apache, un contenedor Docker) y el sitio por defecto "
         "de Nginx no arranca. El script lo desactiva solo; si lo ves, re-ejecuta " +
         m("01", 8.2) + "."),
        ("HTTP 404 en phpMyAdmin",
         "Nginx no puede leer el directorio. Compruébalo con " +
         m("sudo tail /var/log/nginx/pma-error.log", 8.2) + ": si dice <i>Permission denied</i>, "
         "corrige con " + m("sudo chmod 755 /usr/share/phpmyadmin-*", 8.2) + "."),
        ("HTTP 502 Bad Gateway",
         "El socket de PHP-FPM cambió de ruta (p.ej. tras actualizar PHP). Re-ejecuta " +
         m("01", 8.2) + ": lo autodetecta."),
        ("La web no carga por el túnel",
         "Se cerró la sesión " + m("ssh -L", 8.2) + ". Vuelve a abrirla y déjala abierta."),
        ("Access denied for user 'qa_user'",
         "Lee la password real con " + m("sudo cat /root/.qa-db-credentials", 8.2) +
         "; no la teclees de memoria."),
        ("Faltan tablas tras importar",
         "Revisa " + m("/var/log/qa-import-errors.log", 8.2) + ". La carga usa " +
         m("--force", 8.2) + ", así que sigue tras cada error y los acumula ahí. Los "
         "<i>Duplicate foreign key constraint name</i> suelen ser inofensivos: la FK ya quedó "
         "creada. Filtra el ruido con " +
         m("grep -v 'Duplicate foreign key' /var/log/qa-import-errors.log", 8.2) + "."),
        ("Illegal mix of collations en un JOIN",
         "El dump trae varias collations. Si QA debe reproducir producción, déjalas y usa " +
         m("ALLOW_MIXED_COLLATION=1", 8.2) + "; si prefieres unificarlas, convierte las tablas "
         "con " + m("foreign_key_checks=0", 8.2) + " (el comando exacto lo imprime " +
         m("03-verify.sh", 8.2) + ")."),
        ("Importar desde la web falla",
         "Con archivos de más de 100 MB usa siempre " + m("02-import-dump.sh", 8.2) +
         ", no el formulario del navegador."),
    ]))

S.append(Paragraph("Chuleta", H1))
S.append(table2(
    ("Dato", "Dónde"),
    [
        ("Passwords", m("sudo cat /root/.qa-db-credentials", 8.2)),
        ("Base y usuario", m("qa_db", 8.2) + " / " + m("qa_user", 8.2) + " (por defecto)"),
        ("phpMyAdmin", m("http://localhost:8080", 8.2) + " con el túnel abierto"),
        ("Errores de import", m("/var/log/qa-import-errors.log", 8.2)),
        ("Errores de phpMyAdmin", m("/var/log/nginx/pma-error.log", 8.2)),
        ("Errores de MySQL", m("/var/log/mysql/error.log", 8.2)),
        ("Administrar MySQL", m("sudo mysql", 8.2) + " (root entra por socket, sin password)"),
        ("Tuning aplicado", m("/etc/mysql/mysql.conf.d/zz-qa-tuning.cnf", 8.2)),
    ]))

S.append(Paragraph("Mantenimiento", H1))
S.append(Paragraph(
    "phpMyAdmin se instala desde el tarball oficial verificando su SHA256, no por " +
    m("apt") + ", así que <b>" + m("apt upgrade") + " no lo actualiza</b>. Para subirlo de "
    "versión, vuelve a ejecutar " + m("01-install-mysql-pma.sh") + ": instala la última "
    "estable y mueve el symlink " + m("/usr/share/phpmyadmin") + ". Las passwords no cambian "
    "y la base no se toca.", BODY))

doc = SimpleDocTemplate(
    OUT, pagesize=A4,
    leftMargin=2.5 * cm, rightMargin=2.5 * cm,
    topMargin=2.0 * cm, bottomMargin=2.0 * cm,
    title="Guía de instalación - MySQL + phpMyAdmin en QA",
    author="Equipo QA", subject="Instalación de MySQL y phpMyAdmin en Ubuntu Server 26.04",
)
doc.build(S, onFirstPage=footer, onLaterPages=footer)
print("OK ->", OUT)
