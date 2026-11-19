#!/usr/bin/env python3
"""py-schematron.py — Validación Schematron de documentos TEI desde el terminal.

Uso:
    python3 py-schematron.py (-o ODD | -s SCH | -r RNG) [-v] [--max N] DOC.xml [...]

Tres fuentes de reglas, mutuamente excluyentes:
  -o/--odd  ODD con Schematron embebido (p. ej. smed-schema.xml): se extrae
            el .sch con extract-isosch.xsl (TEI Stylesheets) vía Saxon, con
            caché por mtime. Los ODD de personalización SIN reglas embebidas
            (p. ej. tei_all.odd sin compilar) se rechazan con aviso: hay que
            resolverlos antes con odd2odd contra p5subset.xml, o usar -r.
  -s/--sch  ISO Schematron ya extraído: se usa tal cual.
  -r/--rng  RelaxNG generado de un ODD (p. ej. tei_all.rng, smed-schema.rng):
            se cosechan las anotaciones sch:ns / sch:pattern embebidas — las
            mismas reglas que Jing ignora — a un .sch autónomo, con caché
            por mtime.

Ejecución: Saxon (saxonche, XPath 3.1) — superconjunto del binding de oXygen,
de modo que matches(), tokenize(), some/every, if/then/else y <let> se
evalúan de forma idéntica.

Informe: recuento por regla y, con -v, listado por infractor con número de
línea y xml:id del ancestro identificable. Sin tope oculto: --max limita el
detalle, nunca el recuento, y el script declara cuántos quedaron sin listar.
Código de salida: 0 sin infracciones, 1 con infracciones,
2 error de uso, 3 error de entorno (archivo ausente, ODD sin reglas...).

Semántica implementada (subconjunto deliberado de ISO Schematron):
  - pattern / rule / assert / report / let  (let -> "let $x := ... return ...")
    Los <let> de schema y de pattern se anteponen a los de cada regla
    (evaluados en el contexto de la regla, no en la raíz del documento).
  - Contextos relativos ("tei:lem[...]") se evalúan como //(contexto);
    los absolutos ("/tei:TEI/...") tal cual.
  - First-match shadowing DENTRO de cada pattern se respeta.
  - sch:value-of y sch:name en los mensajes se interpolan en el contexto del
    nodo infractor; en el recuento agregado aparecen como '…'.
  - No implementado (el runner avisa una vez por tipo y continúa): phases,
    patterns/reglas abstractos, diagnostics, xsl:key, sqf:fix (Quick Fixes de oXygen: no afectan
    a los veredictos).

Requisitos: Python 3.15 o posterior; pip install saxonche lxml
            odds/extract-isosch.xsl + common/functions.xsl (TEI Stylesheets)
            junto a este script, solo si se usa -o.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from urllib.parse import urlparse
from collections import Counter
from copy import deepcopy
from pathlib import Path

# Python 3.15 o posterior (como pide pyproject.toml). Se comprueba antes de
# importar lxml y saxonche, para que con un Python más antiguo el mensaje
# sea claro: error de entorno, código 3 (la extensión de VS Code lo muestra).
if sys.version_info < (3, 15):
    print(f"py-schematron.py necesita Python 3.15 o posterior; este es Python "
          f"{sys.version.split()[0]}.", file=sys.stderr)
    sys.exit(3)

from lxml import etree
from saxonche import PySaxonProcessor

__version__ = "2.2"

SCH_NS = 'http://purl.oclc.org/dsdl/schematron'
S = f'{{{SCH_NS}}}'
XMLID = '{http://www.w3.org/XML/1998/namespace}id'
HERE = Path(__file__).resolve().parent

_avisados = set()


# Lo que el script hace por el camino (descargas, caché, extracción...):
# cada mensaje va a stderr, como siempre, y además queda aquí, para la
# salida JSON ("events"), de modo que los complementos no tengan que leer
# los mensajes de stderr. Las claves y los tipos están en inglés y son
# estables; el texto ("message") es el mismo de stderr.
EVENTOS = []
ETIQUETAS = {'cache': 'caché', 'download': 'descarga', 'xml-model': 'xml-model',
             'schema': 'esquema', 'extraction': 'extracción', 'harvest': 'cosecha',
             'warning': 'aviso'}
SALIDA_JSON = False          # (--json: también los errores fatales salen en JSON)


def evento(tipo, msg, **datos):
    """Informa de un paso: "[etiqueta] msg" a stderr, y un evento
    {"kind": tipo, "message": msg, ...datos} para la salida JSON."""
    print(f"[{ETIQUETAS[tipo]}] {msg}", file=sys.stderr)
    EVENTOS.append({'kind': tipo, 'message': msg,
                    **{k: (str(v) if isinstance(v, Path) else v) for k, v in datos.items()}})


def avisar_una_vez(clave, msg):
    if clave not in _avisados:
        _avisados.add(clave)
        evento('warning', msg)


def morir(msg):
    """Error de entorno: mensaje a stderr y código de salida 3
    (0 = limpio, 1 = infracciones, 2 = uso, 3 = entorno). Con --json,
    además, {"version", "error", "events"} por stdout, para que quien
    lea el JSON tenga el mensaje sin buscarlo en stderr."""
    print(msg, file=sys.stderr)
    if SALIDA_JSON:
        json.dump({'version': __version__, 'error': msg, 'events': EVENTOS},
                  sys.stdout, ensure_ascii=False, indent=1)
        print()
    sys.exit(3)


def exigir_archivo(path: Path, papel: str):
    if not path.is_file():
        morir(f"No existe {papel}: {path.resolve()}")


def escribir_atomico(dest: Path, datos: bytes):
    """Escribe en un temporal del mismo directorio y lo renombra encima de
    `dest`: un lector concurrente ve el archivo anterior o el nuevo completo,
    nunca uno a medias, y una escritura interrumpida no deja nada en `dest`
    (incidente 2026-11-12: dos validaciones simultáneas al recargar VS Code;
    una leyó el esquema mientras la otra lo escribía)."""
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=f'.{dest.name}.',
                               suffix='.tmp')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(datos)
        mascara = os.umask(0)                   # mkstemp crea con 0600;
        os.umask(mascara)                       # se dejan los permisos de
        os.chmod(tmp, 0o666 & ~mascara)         # un archivo normal
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def bien_formado(path: Path) -> bool:
    try:
        etree.parse(str(path))
        return True
    except etree.XMLSyntaxError:
        return False


def cache_al_dia(fuente: Path, derivado: Path) -> bool:
    """El caché se invalida si cambia la fuente O el propio script (un
    generador corregido debe regenerar sus derivados; episodio 2026-07-12),
    y también si el derivado no es XML bien formado (escrito a medias por
    una versión anterior, sin escritura atómica)."""
    frescura = max(fuente.stat().st_mtime, Path(__file__).stat().st_mtime)
    if derivado.exists() and derivado.stat().st_mtime >= frescura:
        if bien_formado(derivado):
            evento('cache', f"{derivado.name} está al día", file=derivado)
            return True
        evento('warning', f"{derivado.name} está dañado; se regenera", file=derivado)
    return False


# ---------------------------------------------------------------- fuentes

# Carpeta de las TEI Stylesheets para -o (la opción --stylesheets la fija)
HOJAS_TEI = None


def config_odd2rng() -> Path:
    """El config.toml de ODD2RNG (odd2rng.py), que también dice dónde están
    las TEI Stylesheets: $ODD2RNG_CONFIG, o la carpeta de ajustes habitual."""
    if os.environ.get('ODD2RNG_CONFIG'):
        base = Path(os.environ['ODD2RNG_CONFIG']).expanduser()
    elif sys.platform == 'win32':
        base = Path(os.environ.get('APPDATA') or Path.home() / 'AppData' / 'Roaming') / 'odd2rng'
    elif sys.platform == 'darwin':
        base = Path.home() / 'Library' / 'Application Support' / 'odd2rng'
    else:
        base = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'odd2rng'
    return base / 'config.toml'


def hojas_tei():
    """(carpeta, de dónde) de las TEI Stylesheets para -o, o (None, motivo).
    En este orden: --stylesheets, la variable TEI_STYLESHEETS, el ajuste
    `stylesheets` del config.toml de ODD2RNG (una ruta relativa se toma desde
    su carpeta), y por último odds/ y common/ junto a este script."""
    candidatas = []
    if HOJAS_TEI:
        candidatas.append((Path(HOJAS_TEI).expanduser(), '--stylesheets'))
    if os.environ.get('TEI_STYLESHEETS'):
        candidatas.append((Path(os.environ['TEI_STYLESHEETS']).expanduser(), 'TEI_STYLESHEETS'))
    conf = config_odd2rng()
    if conf.is_file():
        try:
            import tomllib
            with open(conf, 'rb') as f:
                valor = tomllib.load(f).get('stylesheets')
            if isinstance(valor, str) and valor:
                d = Path(valor).expanduser()
                candidatas.append((d if d.is_absolute() else conf.parent / d, str(conf)))
        except Exception as e:
            avisar_una_vez('odd2rng-config', f'no pude leer {conf}: {e}')
    candidatas.append((HERE, 'junto al script'))
    for carpeta, origen in candidatas:
        if (carpeta / 'odds' / 'extract-isosch.xsl').is_file():
            return carpeta.resolve(), origen
        if origen != 'junto al script':     # (una indicación explícita que falla)
            return None, f'{carpeta} ({origen}) no tiene odds/extract-isosch.xsl'
    return None, 'ni --stylesheets, ni TEI_STYLESHEETS, ni el config.toml de ODD2RNG, ni odds/ junto al script'


def extraer_sch(odd: Path, proc: PySaxonProcessor) -> Path:
    """ODD -> .sch con extract-isosch.xsl, cacheado por mtime."""
    exigir_archivo(odd, 'el ODD')
    sch = odd.with_suffix('.sch')
    if cache_al_dia(odd, sch):
        return sch
    carpeta, origen = hojas_tei()
    if carpeta is None:
        morir(f"No encuentro las TEI Stylesheets para extraer el Schematron del "
              f"ODD: {origen}. Indica su carpeta (un clon de TEIC/Stylesheets) con "
              f"--stylesheets o TEI_STYLESHEETS, o en el config.toml de ODD2RNG "
              f"(véase README §2).")
    xsl = carpeta / 'odds' / 'extract-isosch.xsl'
    evento('extraction', f"con las TEI Stylesheets de {carpeta} ({origen})",
           stylesheets=carpeta, origin=origen)
    exe = proc.new_xslt30_processor().compile_stylesheet(stylesheet_file=str(xsl))
    try:
        out = exe.transform_to_string(source_file=str(odd))
    except Exception:
        out = None                # extract-isosch aborta con xsl:message si
                                  # el ODD no tiene constraints; unificamos
    if not out or '<pattern' not in out:
        morir(
            f"El ODD {odd.name} no contiene Schematron embebido: la extracción "
            f"produjo un esquema sin patterns, que validaría cualquier documento "
            f"como correcto. Si es un ODD de personalización sin compilar "
            f"(p. ej. tei_all.odd), resuélvelo primero con odd2odd contra "
            f"p5subset.xml, o valida contra su RelaxNG generado con -r "
            f"(véase README §7).")
    escribir_atomico(sch, out.encode('utf-8'))
    evento('extraction', f"{odd.name} -> {sch.name}", source=odd.resolve(), file=sch.resolve())
    return sch


def sch_desde_rng(rng: Path) -> Path:
    """Cosecha los sch:ns y sch:pattern embebidos en un RelaxNG generado de
    un ODD, deduplicados, a un .sch autónomo. Cacheado por mtime."""
    exigir_archivo(rng, 'el RelaxNG')
    out = rng.with_suffix('.harvested.sch')
    if cache_al_dia(rng, out):
        return out
    t = etree.parse(str(rng))
    schema = etree.Element(S + 'schema', nsmap={None: SCH_NS})
    schema.set('queryBinding', 'xslt2')
    vistos, n_ns, n_pat = set(), 0, 0
    for tag in ('ns', 'pattern'):
        for el in t.iter(S + tag):
            copia = deepcopy(el)
            copia.tail = None
            clave = etree.tostring(copia)
            if clave in vistos:
                continue
            vistos.add(clave)
            schema.append(copia)
            if tag == 'ns':
                n_ns += 1
            else:
                n_pat += 1
    if not n_pat:
        morir(f"El RelaxNG {rng.name} no contiene anotaciones Schematron "
              f"embebidas (¿fue generado sin ellas?).")
    # Poda de declaraciones de namespace rancias arrastradas por deepcopy:
    # sin esto, lxml puede serializar un elemento {ISO}x sin prefijo bajo una
    # declaración heredada xmlns="TEI", corrompiendo el namespace en el
    # viaje árbol -> bytes -> árbol (verificado con tei_all.rng).
    etree.cleanup_namespaces(schema, top_nsmap={None: SCH_NS})
    datos = etree.tostring(etree.ElementTree(schema), encoding='utf-8',
                           xml_declaration=True, pretty_print=True)
    # Self-check: lo re-parseado debe contener exactamente lo cosechado. Se
    # hace sobre los bytes, ANTES de escribir: un esquema mutilado nunca
    # llega al caché.
    chk = etree.fromstring(datos)
    chk_pat = len(chk.findall(S + 'pattern'))
    chk_ns = len(chk.findall(S + 'ns'))
    if (chk_pat, chk_ns) != (n_pat, n_ns):
        morir(f"Self-check de cosecha fallido en {out.name}: cosechados "
              f"{n_pat} patterns/{n_ns} ns, re-leídos {chk_pat}/{chk_ns}. "
              f"Corrupción de namespaces en la serialización; no se valida "
              f"contra un esquema mutilado.")
    escribir_atomico(out, datos)
    evento('harvest', f"{rng.name} -> {out.name} ({n_pat} patterns, {n_ns} ns)",
           source=rng.resolve(), file=out.resolve(), patterns=n_pat, namespaces=n_ns)
    return out


# ----------------------------------------------------- autodetección

RELAXNG_NS = 'http://relaxng.org/ns/structure/1.0'
TEI_NS = 'http://www.tei-c.org/ns/1.0'


def obtener_recurso(href, base_dir: Path, refresh=False) -> Path:
    """Resuelve el href de una PI xml-model: ruta local (relativa al
    documento) o URL http(s), que se descarga a un caché junto al script
    (.schema-cache/, nombre = hash de la URL + nombre original)."""
    if re.match(r'https?://', href):
        cache = HERE / '.schema-cache'
        cache.mkdir(exist_ok=True)
        nombre = (hashlib.sha256(href.encode()).hexdigest()[:12]
                  + '-' + (Path(urlparse(href).path).name or 'schema'))
        dest = cache / nombre
        if dest.exists() and not refresh:
            if bien_formado(dest):
                evento('cache', f"{href} ya descargado -> {dest.name} "
                                f"(--refresh para forzar)", url=href, file=dest)
                return dest
            evento('warning', f"la copia en caché de {href} está incompleta o "
                              f"dañada; se vuelve a descargar", url=href, file=dest)
        evento('download', href, url=href, file=dest)
        try:
            with urllib.request.urlopen(href, timeout=60) as r:
                datos = r.read()
        except Exception as e:
            morir(f"No pude descargar el esquema {href}: {e}")
        try:
            etree.fromstring(datos)
        except etree.XMLSyntaxError as e:
            morir(f"Lo descargado de {href} no es XML bien formado ({e}); "
                  f"no se guarda en caché.")
        escribir_atomico(dest, datos)
        return dest
    p = (base_dir / href).resolve() if not Path(href).is_absolute() else Path(href)
    exigir_archivo(p, f"el esquema referido por xml-model ({href})")
    return p


def clasificar_esquema(path: Path) -> str:
    """Clasifica por CONTENIDO real (no por extensión): 'rng' | 'sch' | 'odd'."""
    try:
        root = etree.parse(str(path)).getroot()
    except etree.XMLSyntaxError as e:
        morir(f"El esquema {path.name} no es XML bien formado: {e}")
    ns = etree.QName(root).namespace
    if ns == RELAXNG_NS:
        return 'rng'
    if ns == SCH_NS:
        return 'sch'
    if ns == TEI_NS:
        return 'odd'
    morir(f"No reconozco el esquema {path.name} (raíz en namespace {ns}); "
          f"indícalo explícitamente con -o, -s o -r.")


def href_xml_model(doc_path: Path, preferencia=(SCH_NS, RELAXNG_NS)):
    """href de la PI <?xml-model?> del documento: la primera cuyo
    schematypens figure en `preferencia` (por orden); en su defecto, la
    primera PI con href. Termina con código 3 si no hay ninguna.
    El análisis es tolerante (recover): las PIs van en el prólogo y deben
    poder leerse aunque el cuerpo esté a medio escribir; la buena formación
    la juzga después validar(), que la informa con su número de línea."""
    exigir_archivo(doc_path, 'el documento')
    try:
        tree = etree.parse(str(doc_path), etree.XMLParser(recover=True))
    except etree.XMLSyntaxError as e:
        morir(f"El documento {doc_path.name} no está bien formado: {e}")
    if tree.getroot() is None:
        morir(f"El documento {doc_path.name} no contiene XML legible.")
    entradas = [(pi.get('href'), pi.get('schematypens') or '')
                for pi in tree.xpath('//processing-instruction("xml-model")')
                if pi.get('href')]
    if not entradas:
        morir(f"{doc_path.name} no lleva ninguna PI <?xml-model?> con href; "
              f"indica el esquema explícitamente.")
    for ns in preferencia:
        for href, tipo in entradas:
            if tipo == ns:
                return href
    return entradas[0][0]


def detectar_esquema(doc_path: Path, refresh=False, base_dir: Path = None):
    """Lee las PIs <?xml-model?> del documento y devuelve (ruta, tipo).
    Preferencia: una PI con schematypens de Schematron; en su defecto, la
    de RelaxNG (cuyo Schematron embebido se cosechará); hrefs duplicados
    (el patrón habitual: el mismo .rng asociado dos veces, una por capa)
    cuentan como una sola fuente. La clasificación final es por contenido,
    no por extensión ni por lo que la PI declare. Los hrefs relativos se
    resuelven contra `base_dir` (por defecto, el directorio del documento)."""
    href = href_xml_model(doc_path)
    evento('xml-model', f"esquema detectado: {href}", href=href)
    local = obtener_recurso(href, base_dir or doc_path.parent, refresh)
    tipo = clasificar_esquema(local)
    evento('xml-model', f"clasificado por contenido como: {tipo}", type=tipo, file=local)
    return local, tipo


# ---------------------------------------------------------------- esquema

def leer_lets(el):
    return [(l.get('name'), l.get('value')) for l in el.findall(S + 'let')]


def espacios(texto):
    """Colapsa espacios en blanco y recorta los extremos."""
    return re.sub(r'\s+', ' ', texto).strip()


def leer_mensaje(t):
    """Mensaje de un assert/report: plantilla estática (con '…' en lugar de
    lo dinámico, para agrupar el recuento) y segmentos ('txt' | 'exp') para
    interpolar. sch:value-of aporta su @select; sch:name, el nombre del nodo
    de contexto (o de su @path). Los segmentos de texto conservan sus
    espacios de borde: 'corresp="<value-of/>"' no debe convertirse en
    'corresp=" # "'."""
    segs = [('txt', t.text or '')]
    for hijo in t:
        if isinstance(hijo.tag, str):
            hq = etree.QName(hijo)
            if hq.namespace == SCH_NS and hq.localname == 'value-of':
                segs.append(('exp', hijo.get('select')))
            elif hq.namespace == SCH_NS and hq.localname == 'name':
                segs.append(('exp', f"name({hijo.get('path') or '.'})"))
            else:                               # emph, dir, span...
                segs.append(('txt', ''.join(hijo.itertext())))
        segs.append(('txt', hijo.tail or ''))
    segs = [(k, v) for k, v in segs if v]
    msg = espacios(''.join(v if k == 'txt' else '…' for k, v in segs))
    return msg, segs


def cargar_reglas(sch_path: Path):
    """Devuelve (namespaces, patterns); cada pattern es (id, [reglas]), cada
    regla (context, [tests], conjunta, lote, selección) y cada test (tipo,
    xpath, mensaje, segmentos, role, ubicación), donde la ubicación es
    {"file", "line"} del assert o report en sch_path (ubicar_en_fuente la
    lleva al ODD o al RelaxNG de origen). Los <let> ya van integrados en las
    expresiones XPath de tests, segmentos y selección: los de schema y de
    pattern (por ese orden) ligados con la raíz del documento como contexto
    (con_globales), y los de la regla con su nodo de contexto (con_lets),
    como manda ISO Schematron.  `selección` es la expresión que da los
    nodos de contexto de la regla.

    `conjunta` evalúa todos los tests de la regla en una sola llamada, con
    los <let> calculados una vez por nodo, como manda ISO Schematron; por
    separado, cada test los recalcula, y en una regla con muchos tests y
    variables costosas eso multiplica el tiempo. Devuelve un xs:boolean por
    test, en orden. Es None si la regla tiene un solo test.

    `lote` evalúa la regla entera en una sola llamada: recorre sus nodos de
    contexto en orden de documento y devuelve, por cada uno, su path(.) y el
    xs:boolean de cada test. Saxon compila cada expresión que recibe, así
    que una llamada por nodo recompila la regla miles de veces; en una sola,
    se compila una vez (en la edición latina, la regla de <app> pasó de
    9 s a 0,6 s). Los nodos que el shadowing descarta se evalúan también,
    y sus resultados se ignoran; si eso provoca un error, la regla se
    evalúa nodo a nodo, como antes."""
    exigir_archivo(sch_path, 'el Schematron')
    root = etree.parse(str(sch_path)).getroot()
    nss = {ns.get('prefix'): ns.get('uri') for ns in root.iter(S + 'ns')
           if ns.get('prefix')}
    lets_schema = leer_lets(root)
    patterns = []
    for pat in root.iter(S + 'pattern'):
        if pat.get('abstract') == 'true' or pat.get('is-a'):
            avisar_una_vez('abstract',
                           'patterns abstractos/is-a no implementados: omitidos')
            continue
        # <let> de schema y de pattern: según ISO Schematron se evalúan con
        # la raíz del documento como contexto, no con el nodo de la regla
        globales = lets_schema + leer_lets(pat)
        reglas = []
        for rule in pat.findall(S + 'rule'):
            if rule.get('abstract') == 'true':
                avisar_una_vez('abstract-rule',
                               'reglas abstractas no implementadas: omitidas')
                continue
            lets = leer_lets(rule)              # (los de la regla: por nodo)
            tests, crudos = [], []
            for t in rule:
                if not isinstance(t.tag, str):      # comentarios, PIs
                    continue
                qn = etree.QName(t)
                if qn.namespace != SCH_NS:
                    avisar_una_vez(f'ns:{qn.namespace}',
                                   f'elementos ajenos a Schematron ignorados '
                                   f'(p. ej. {qn.localname} de {qn.namespace}); '
                                   f'no afectan a los veredictos')
                elif qn.localname in ('assert', 'report'):
                    msg, segs = leer_mensaje(t)
                    # value-of produce el VALOR de cadena de cada ítem (no
                    # su serialización: un atributo daría 'x="v"').
                    segs = [(k, con_globales(globales,
                                             'string-join((for $VALIDATE_V in ('
                                             f'{con_lets(lets, v)}) return '
                                             "string($VALIDATE_V)), ' ')"))
                            if k == 'exp' else (k, v)
                            for k, v in segs]
                    tests.append((qn.localname,
                                  con_globales(globales, con_lets(lets, t.get('test'))),
                                  msg, segs, t.get('role') or '',
                                  {'file': str(sch_path.resolve()), 'line': t.sourceline,
                                   'kind': qn.localname, 'test': t.get('test')}))
                    crudos.append(t.get('test'))
                elif qn.localname != 'let':
                    avisar_una_vez(f'el:{qn.localname}',
                                   f'elemento Schematron no implementado: '
                                   f'{qn.localname} (omitido)')
            ctx = rule.get('context')
            todos = '(' + ', '.join(f'boolean(({c}))' for c in crudos) + ')'
            conjunta = (con_globales(globales, con_lets(lets, todos))
                        if len(crudos) > 1 else None)
            sel = ctx if ctx.startswith('/') else f'//({ctx})'
            lote = con_globales(globales,
                                f'for $VALIDATE_N in ({sel}) return $VALIDATE_N/'
                                f'(string(path(.)){", " + con_lets(lets, todos) if crudos else ""})')
            reglas.append((ctx, tests, conjunta, lote, con_globales(globales, sel)))
        if reglas:
            patterns.append((pat.get('id') or '', reglas))
    if root.find(S + 'phase') is not None:
        avisar_una_vez('phase', 'phases no implementadas: se ejecutan '
                                'todos los patterns')
    return nss, patterns


def con_globales(lets, expr):
    """Liga los <let> de schema y de pattern con la raíz del documento como
    contexto, como manda ISO Schematron, sea cual sea el nodo con que se
    evalúe EXPR: root(.) ! (valor).  (El operador ! no reordena ni quita
    duplicados, a diferencia de /.)  En la llamada única de cada regla se
    evalúan una sola vez, fuera del recorrido de sus nodos."""
    for name, value in reversed(lets):
        expr = f"let ${name} := (root(.) ! ({con_lets([], value)})) return ({expr})"
    return expr


def con_lets(lets, expr):
    for name, value in reversed(lets):
        expr = f"let ${name} := ({value}) return ({expr})"
    # current() es XSLT, no XPath: en Schematron refiere al nodo de contexto
    # de la regla. Se liga en la posición más externa y se sustituye, lo que
    # reproduce exactamente esa semántica (las Guidelines P5 lo usan).
    if 'current()' in expr:
        expr = expr.replace('current()', '$VALIDATE_CTX')
        expr = f"let $VALIDATE_CTX := . return ({expr})"
    return expr


# ------------------------------------------------------------- validación

def ruta_lxml(path_q, nss):
    """fn:path() (notación Q{uri}local) -> XPath 1.0 evaluable por lxml."""
    def paso(m):
        uri, local = m.group(1), m.group(2)
        if not uri:
            return local
        for pre, u in nss.items():
            if u == uri:
                return f'{pre}:{local}'
        return f"*[local-name()='{local}' and namespace-uri()='{uri}']"
    return re.sub(r'Q\{([^}]*)\}([^\[/]+)', paso, path_q)


class DocumentoMalFormado(Exception):
    def __init__(self, msg, line=None):
        super().__init__(msg)
        self.line = line


def ubicar_en_fuente(patterns, fuente: Path):
    """Lleva la ubicación de cada assert y report del .sch (extraído de un
    ODD o cosechado de un RelaxNG) a su origen, el archivo que se edita:
    el n-ésimo assert/report de la fuente con el mismo tipo y la misma
    expresión @test es el n-ésimo del .sch, pues extracción y cosecha
    conservan el orden. Los que no se encuentran conservan su ubicación
    en el .sch."""
    try:
        raiz = etree.parse(str(fuente)).getroot()
    except Exception:
        return
    en_fuente = {}
    for el in raiz.iter(S + 'assert', S + 'report',
                        '{http://www.ascc.net/xml/schematron}assert',
                        '{http://www.ascc.net/xml/schematron}report'):
        clave = (etree.QName(el).localname, espacios(el.get('test') or ''))
        en_fuente.setdefault(clave, []).append(el.sourceline)
    vistos = Counter()
    ruta = str(Path(fuente).resolve())
    for _, reglas in patterns:
        for _, tests, *_ in reglas:
            for t in tests:
                u = t[5]
                clave = (u['kind'], espacios(u['test'] or ''))
                n = vistos[clave]
                vistos[clave] += 1
                lineas = en_fuente.get(clave, [])
                if n < len(lineas):
                    u['file'], u['line'] = ruta, lineas[n]


def validar(doc_path: Path, nss, patterns, proc, n_lineas=None, nombre=None):
    """Valida un documento y devuelve un dict con sus infracciones (cada una
    con pattern, contexto, tipo, role, mensaje, texto interpolado, path y,
    para las primeras `n_lineas` —todas si es None—, línea y xml:id), los
    errores XPath agrupados por regla y el tiempo empleado. `nombre` es el
    nombre que se muestra en los mensajes (con --as, el del documento real
    y no el del temporal)."""
    exigir_archivo(doc_path, 'el documento')
    nombre = nombre or doc_path.name
    try:
        lx = etree.parse(str(doc_path))      # para números de línea
    except etree.XMLSyntaxError as e:
        raise DocumentoMalFormado(
            f"El documento {nombre} no está bien formado: {e.msg}. "
            f"Corrígelo antes de validar (xmllint --noout lo localiza).",
            e.lineno)
    xp = proc.new_xpath_processor()
    for p, u in nss.items():
        xp.declare_namespace(p, u)
    doc = proc.parse_xml(xml_file_name=str(doc_path))
    xp.set_context(xdm_item=doc)

    def en(node, metodo, expr):
        """Evalúa expr con `node` como contexto y restaura el documento."""
        xp.set_context(xdm_item=node)
        try:
            return metodo(expr)
        finally:
            xp.set_context(xdm_item=doc)

    def nodos(seleccion):
        r = xp.evaluate(seleccion)
        if r is None:
            return []
        return [r[i] for i in range(r.size)] if hasattr(r, 'size') else [r]

    def evaluar_juntos(node, conjunta, n):
        """Los n tests de una regla en una sola llamada (sus <let> se
        calculan una vez); None si la regla no la tiene o si la llamada
        falla, y entonces se evalúan uno a uno, para que un test roto se
        informe solo, como siempre."""
        if conjunta is None:
            return None
        try:
            r = en(node, xp.evaluate, conjunta)
        except Exception:
            return None
        items = [] if r is None else ([r[i] for i in range(r.size)] if hasattr(r, 'size') else [r])
        if len(items) != n:
            return None
        return [str(item) == 'true' for item in items]

    def evaluar_lote(lote, n_tests, n_nodos):
        """La regla entera en una llamada: [(path, [valores])] por nodo, en
        el orden de nodos(ctx); None si la llamada falla o el resultado no
        cuadra, y entonces la regla se evalúa nodo a nodo."""
        try:
            r = xp.evaluate(lote)
        except Exception:
            return None
        items = [] if r is None else ([r[i] for i in range(r.size)] if hasattr(r, 'size') else [r])
        paso = 1 + n_tests
        if len(items) != paso * n_nodos:
            return None
        textos = [str(item) for item in items]
        return [(textos[i], [t == 'true' for t in textos[i + 1:i + paso]])
                for i in range(0, len(textos), paso)]

    def interpolar(node, msg, segs):
        if not any(k == 'exp' for k, _ in segs):
            return msg
        try:
            partes = []
            for k, v in segs:
                if k == 'txt':
                    partes.append(v)
                else:
                    r = en(node, xp.evaluate, v)
                    partes.append(str(r) if r is not None else '')
            return espacios(''.join(partes))
        except Exception:
            return msg

    def linea_e_id(path_q):
        """Número de línea y xml:id del ancestro identificable, vía lxml."""
        try:
            tgt = lx.xpath(ruta_lxml(path_q, nss), namespaces=nss)
            if tgt:
                el = tgt[0]
                if not isinstance(el, etree._Element):   # atributo, texto
                    el = el.getparent()
                anc = el.xpath('ancestor-or-self::*[@xml:id][1]')
                xid = anc[0].get(XMLID) if anc else '—'
                return el.sourceline, xid
        except Exception:
            pass
        return None, '—'

    infracciones = []
    errores = Counter()
    t0 = time.time()
    for pat_id, reglas in patterns:
        ya_casados = set()                    # first-match shadowing
        for ctx, tests, conjunta, lote, seleccion in reglas:
            try:
                lista = nodos(seleccion)
            except Exception as e:             # (un contexto que no se evalúa)
                u = tests[0][5] if tests else {'file': None, 'line': None}
                errores[('(context)', ctx, str(e).strip(), u['file'], u['line'])] += 1
                continue
            de_lote = evaluar_lote(lote, len(tests), len(lista))
            for k, node in enumerate(lista):
                if de_lote is not None:
                    path_id, valores = de_lote[k]
                else:                          # (nodo a nodo)
                    path_id = str(en(node, xp.evaluate_single, 'path(.)'))
                if path_id in ya_casados:
                    continue
                ya_casados.add(path_id)
                if de_lote is None:
                    valores = evaluar_juntos(node, conjunta, len(tests))
                for i, (tipo, test, msg, segs, role, ubic) in enumerate(tests):
                    if valores is not None:
                        val = valores[i]
                    else:                      # (uno a uno: aísla los errores)
                        try:
                            val = en(node, xp.effective_boolean_value, test)
                        except Exception as e:
                            errores[(msg, ctx, str(e).strip(), ubic['file'], ubic['line'])] += 1
                            continue
                    if val == (tipo == 'report'):
                        infracciones.append({
                            'pattern': pat_id, 'context': ctx, 'type': tipo,
                            'role': role, 'message': msg,
                            'text': interpolar(node, msg, segs),
                            'path': path_id, 'line': None, 'xml_id': None,
                            'rule': {'file': ubic['file'], 'line': ubic['line']}})
    segundos = time.time() - t0
    for inf in infracciones[:n_lineas]:
        inf['line'], xid = linea_e_id(inf['path'])
        inf['xml_id'] = None if xid == '—' else xid
    return {
        'file': str(doc_path),
        'violations': infracciones,
        'xpath_errors': [{'message': m, 'context': c, 'error': e, 'nodes': n,
                          'rule': {'file': f, 'line': l}}
                         for (m, c, e, f, l), n in errores.items()],
        'seconds': round(segundos, 3),
    }


def informe_texto(res, verbose=False, max_list=50):
    """Informe para el terminal (el formato de siempre)."""
    infracciones, errores = res['violations'], res['xpath_errors']
    for e in errores:
        print(f"[ERROR XPath] regla '{e['message'][:50]}': {e['error']} "
              f"({e['nodes']} nodos)", file=sys.stderr)
    print(f"\n== {Path(res['file']).name} — {len(infracciones)} infracciones "
          f"({res['seconds']:.1f}s) ==")
    if errores:
        print(f"[!] {sum(e['nodes'] for e in errores)} evaluaciones fallidas "
              f"en {len(errores)} reglas: el veredicto es INCOMPLETO")
    for msg, n in Counter(i['message'] for i in infracciones).most_common():
        print(f"{n:5d}  {msg[:100]}")
    if verbose and infracciones:
        print(f"\n-- detalle (primeras {min(max_list, len(infracciones))}) --")
        for i in infracciones[:max_list]:
            print(f"  l.{i['line'] or '?':>6}  [{i['xml_id'] or '—'}]  "
                  f"{i['text'][:140]}")
        if len(infracciones) > max_list:
            print(f"  ... y {len(infracciones)-max_list} más (sube --max)")


# ------------------------------------------------------------------ main

def acerca() -> str:
    """El texto de --about: qué es, de quién, con qué licencia y dónde
    está, y con qué corre aquí (Python, saxonche, lxml, Saxon, el caché y
    las hojas de estilo de TEI para -o)."""
    from importlib.metadata import version, PackageNotFoundError

    def de(paquete):
        try:
            return version(paquete)
        except PackageNotFoundError:
            return '?'
    try:
        with PySaxonProcessor(license=False) as proc:
            saxon = proc.version
    except Exception as e:                        # (no debería pasar)
        saxon = f'no disponible ({e})'
    carpeta, origen = hojas_tei()
    lxml_v = '.'.join(map(str, etree.LXML_VERSION[:3]))
    libxml2 = '.'.join(map(str, etree.LIBXML_VERSION))
    return f"""py-schematron.py {__version__}
Validación ISO Schematron de documentos XML/TEI con Saxon (XPath 3.1): las
reglas de un ODD, de un .sch o de un RelaxNG con reglas embebidas, con el
esquema detectado por <?xml-model?>, como en oXygen.

Autor:         Nicolas Vaughan <nicolasvaughan@proton.me>
Licencia:      GNU General Public License, versión 3 o posterior
Código:        https://codeberg.org/nivaca/py-schematron
               https://github.com/nivaca/py-schematron
Complementos:  https://codeberg.org/nivaca/py-schematron-vscode (VS Code)
               https://codeberg.org/nivaca/py-schematron.el (Emacs)

Este script:   {Path(__file__).resolve()}
Python:        {sys.version.split()[0]} ({sys.executable})
saxonche:      {de('saxonche')} ({saxon})
lxml:          {lxml_v} (libxml2 {libxml2})
Caché:         {HERE / '.schema-cache'}
TEI Stylesheets para -o: {f'{carpeta} ({origen})' if carpeta else f'no encontradas: {origen}'}"""


class Acerca(argparse.Action):
    """--about: imprime acerca() y termina, como --version."""

    def __init__(self, option_strings, dest, **kwargs):
        super().__init__(option_strings, dest, nargs=0, **kwargs)

    def __call__(self, parser, namespace, values, option_string=None):
        global HOJAS_TEI
        HOJAS_TEI = getattr(namespace, 'stylesheets', None) or HOJAS_TEI
        print(acerca())
        parser.exit()


def main():
    ap = argparse.ArgumentParser(
        description='Validación Schematron de documentos TEI desde el terminal')
    ap.add_argument('--version', action='version',
                    version=f'%(prog)s {__version__}')
    ap.add_argument('--stylesheets', metavar='CARPETA',
                    help='las TEI Stylesheets para -o (un clon de TEIC/Stylesheets); '
                         'si no, TEI_STYLESHEETS, el config.toml de ODD2RNG, u '
                         'odds/ y common/ junto al script')
    ap.add_argument('--about', action=Acerca,
                    help='qué es este programa, de quién, con qué licencia y '
                         'dónde está, y con qué Python y bibliotecas corre')
    ap.add_argument('docs', nargs='+', type=Path)
    g = ap.add_mutually_exclusive_group(required=False)
    g.add_argument('-o', '--odd', type=Path,
                   help='ODD con Schematron embebido del que extraer el .sch')
    g.add_argument('-s', '--sch', type=Path, help='.sch ya extraído')
    g.add_argument('-r', '--rng', type=Path,
                   help='RelaxNG generado de un ODD; se cosecha su Schematron embebido')
    ap.add_argument('-v', '--verbose', action='store_true',
                    help='listado detallado con líneas y xml:ids')
    ap.add_argument('--max', type=int, default=50,
                    help='máximo de infracciones detalladas (def. 50; '
                         'el recuento total nunca se trunca)')
    ap.add_argument('--refresh', action='store_true',
                    help='con autodetección por xml-model: volver a '
                         'descargar el esquema aunque esté en caché')
    ap.add_argument('--json', action='store_true',
                    help='salida JSON por stdout (todas las infracciones, con '
                         'línea y xml:id; ignora -v y --max); los mensajes de '
                         'diagnóstico siguen yendo a stderr')
    ap.add_argument('--as', dest='como', type=Path, metavar='RUTA',
                    help='con un único documento: tratarlo como si estuviera '
                         'en RUTA (resolución de hrefs relativos de xml-model '
                         'y nombre en el informe). La extensión de VS Code lo '
                         'usa para validar el texto sin guardar a partir de '
                         'una copia temporal')
    args = ap.parse_args()
    global HOJAS_TEI, SALIDA_JSON
    HOJAS_TEI = args.stylesheets
    SALIDA_JSON = args.json
    if args.como and len(args.docs) != 1:
        ap.error('--as requiere exactamente un documento')
    base = args.como.resolve().parent if args.como else None
    nombre = args.como.name if args.como else None

    resultados, mal_formados = [], 0
    with PySaxonProcessor(license=False) as proc:
        if args.odd:
            fuente, tipo = args.odd, 'odd'
        elif args.rng:
            fuente, tipo = args.rng, 'rng'
        elif args.sch:
            fuente, tipo = args.sch, 'sch'
        else:
            fuente, tipo = detectar_esquema(args.docs[0], args.refresh, base)
            if len(args.docs) > 1:
                evento('warning', "esquema detectado del PRIMER documento; se "
                                  "aplica a todos los de esta invocación")
        if tipo == 'odd':
            sch = extraer_sch(fuente, proc)
        elif tipo == 'rng':
            sch = sch_desde_rng(fuente)
        else:
            sch = fuente
        nss, patterns = cargar_reglas(sch)
        if tipo in ('odd', 'rng'):
            ubicar_en_fuente(patterns, fuente)
        n_reglas = sum(len(r) for _, r in patterns)
        evento('schema', f"{len(patterns)} patterns, {n_reglas} reglas, "
                         f"prefijos: {', '.join(nss)}",
               file=Path(sch).resolve(), patterns=len(patterns), rules=n_reglas,
               prefixes=list(nss))
        for d in args.docs:
            try:
                res = validar(d, nss, patterns, proc,
                              n_lineas=None if args.json else
                              (args.max if args.verbose else 0),
                              nombre=nombre)
            except DocumentoMalFormado as e:
                if not args.json:
                    morir(str(e))
                mal_formados += 1
                resultados.append({'file': str(args.como or d), 'error': str(e),
                                   'error_line': e.line})
                continue
            if args.como:
                res['file'] = str(args.como)
            resultados.append(res)
            if not args.json:
                informe_texto(res, args.verbose, args.max)
    if args.json:
        json.dump({'version': __version__, 'schema': str(sch),
                   'source': {'path': str(Path(fuente).resolve()),
                              'type': tipo},
                   'documents': resultados, 'events': EVENTOS}, sys.stdout,
                  ensure_ascii=False, indent=1)
        print()
    # 3: algún documento no está bien formado, o alguna regla no se pudo
    # evaluar (el veredicto está incompleto); 1: infracciones; 0: nada.
    if mal_formados or any(r.get('xpath_errors') for r in resultados):
        sys.exit(3)
    sys.exit(1 if any(r.get('violations') for r in resultados) else 0)


if __name__ == '__main__':
    main()
