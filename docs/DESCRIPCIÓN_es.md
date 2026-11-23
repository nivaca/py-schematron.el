# py-schematron.el 1.0.2: descripción

## Análisis

py-schematron.el es un paquete de Emacs que revisa documentos XML y TEI contra las reglas Schematron de su esquema mientras se escribe, y subraya cada infracción en el buffer, con Flymake o con Flycheck. Fue desarrollado por Nicolas Vaughan en noviembre de 2026 para las ediciones del proyecto SMTrad, después de la extensión de Visual Studio Code, que ya había mostrado qué debía hacer una herramienta así dentro de un editor. Hasta la versión 0.7.0 se llamó py-xmlvalidate, y hasta la 0.2.0 vivió en la carpeta `emacs/` del repositorio del programa.

El paquete no valida por sí mismo: ejecuta py-schematron.py, el programa del proyecto py-schematron, que da un informe JSON con cada infracción, su línea, su regla y dónde está escrita esa regla, y jing cuando el esquema es RelaxNG. De ahí salieron los requisitos. Había que revisar el texto que se está editando, cambios sin guardar incluidos, sin escribir nunca junto al archivo del usuario; cancelar una revisión cuando llega otra más nueva y no dejar procesos ni copias temporales; servir tanto con Flymake, que viene con Emacs, como con Flycheck; y respetar la regla de `trusted-content` de Emacs 31, porque el `<?xml-model?>` de un documento elige el esquema y Saxon ejecuta su XPath, que puede leer archivos y pedir URL.

Pronto se sumó otro requisito: que nxml-mode, el modo de Emacs para XML, conociera el esquema del documento, para completar los elementos y atributos que permite. nxml solo lee la sintaxis compacta de RelaxNG y no entiende `<?xml-model?>`, y sobre las ediciones rechazaba valores que el esquema admite, por cuatro errores en sus tipos de datos XSD.

## Diseño

Todo el paquete está en un archivo, `py-schematron.el`, con su copia de py-schematron.py al lado. Se pensó en un servidor de lenguaje compartido con VS Code y se descartó: Python con sus bibliotecas arranca en unos 15 ms, y el tiempo de una edición grande se va en las reglas mismas, de modo que un proceso permanente no habría ahorrado nada que justificara su complejidad.

El modo menor `py-schematron-mode` registra un backend de Flymake o un comprobador de Flycheck; la opción `py-schematron-frontend` elige, y por omisión se usa Flycheck cuando está instalado. Ambos escriben el buffer en una carpeta temporal privada y ejecutan `py-schematron.py --json --as ARCHIVO`, que trata la copia como si fuera el archivo real, de modo que las rutas relativas de `<?xml-model?>` siguen sirviendo. Las órdenes son `py-schematron-check`, `-refresh-schema` (vuelve a descargar un esquema remoto), `-report` (el informe completo), `-goto-rule` (abre el esquema en la regla de un error), `-trust-file`, `-recreate-nxml-schema`, `-check-setup`, `-show-log` y `-about`.

Después de cada revisión, el paquete convierte el esquema RelaxNG a la sintaxis compacta con trang, guarda la conversión en un caché y se la da a nxml; un esquema elegido a mano nunca se reemplaza. Los cuatro errores de nxml se corrigen solo si el Emacs en uso los tiene, y cuando el modo se activa en un buffer de nxml-mode, no al cargar el paquete.

## Implementación

Está escrito en Emacs Lisp, en unas 1530 líneas, sin más dependencias que Emacs 31; Flycheck, jing y trang son opcionales.

### La regla de confianza

Emacs 31 solo deja que Flymake corra sobre los archivos de `trusted-content`, salvo que el backend se declare siempre seguro. Se decidió no declararlo. Un archivo fuera de esa lista recibe un aviso, una vez, con la línea que hay que añadir al archivo de inicio, y `M-x py-schematron-trust-file` confía en él o en su carpeta después de preguntar. Flycheck no tiene esa regla, así que el paquete la aplica por su cuenta. En Windows, Flymake sí llama al backend para un archivo no confiable; desde la versión 0.10.1 el propio backend lo rechaza.

### Los errores de nxml

Al construir una categoría Unicode como `\p{P}`, `xsdre-range-list-union` fusionaba las listas en su lugar y dañaba la tabla guardada de la última categoría; las categorías de nxml son de Unicode 3.1 y no pasan de U+FFFF, y los valores `xsd:token` conservaban un espacio en los extremos. El paquete prueba cada error en el Emacs en uso (por ejemplo, le da a la función dos listas nuevas y ve si las cambia) y lo corrige solo si está: con un *advice* que copia las listas, y reconstruyendo las categorías con los datos Unicode del propio Emacs, con cachés para que nxml no sea más lento. Desde la 1.0.2, por consejo del mantenedor de Emacs, las categorías se leen de la tabla de la propiedad general-category, que da el nombre de la categoría de cada carácter (como en characters.el). Los cuatro errores se informaron a Emacs (bug#82281 a bug#82284); los informes están en `upstream/`.

### Windows

Emacs en Windows lee la salida de los procesos con la página de códigos del sistema, de modo que el paquete la lee explícitamente como UTF-8, con el fin de línea detectado. Windows no tiene una orden `jing`: `py-schematron-jing` acepta un `jing.jar`, que se ejecuta con Java, o una línea de órdenes, y si no encuentra jing usa el `jing.jar` de la variable `JING_JAR`.

### El programa y los nombres antiguos

Cada versión del paquete lleva su copia de py-schematron.py, que `tools/sync-plugins.py`, en el repositorio del programa, actualiza. Con `py-schematron-python` en nil, el paquete usa el Python del entorno que crea el instalador de py-schematron. Los nombres `py-xmlvalidate-…` funcionaron como alias obsoletos entre la 0.8.0 y la 1.0.0, que los quitó.

## Validación

El paquete tiene 46 pruebas de ERT (`test/py-schematron-tests.el`), que corren en un Emacs sin pantalla. Unas no necesitan Python: leen los informes de py-schematron.py y de jing, buscan el programa (también mediante un enlace como los de Straight), eligen la orden de jing y comprueban los arreglos de nxml en un Emacs nuevo, y que cargar el paquete no cambie nada. Las demás ejecutan los programas reales sobre documentos hechos para cada caso, mediante Flymake, Flycheck y trang: las líneas y los subrayados, un elemento mal escrito, el texto sin guardar, la revisión cancelada por otra más nueva, un esquema remoto refrescado desde un pequeño servidor web, el archivo fuera de `trusted-content` (su aviso, las órdenes que se niegan y el rechazo del propio backend), los mensajes con tildes, que no quede ningún proceso ni copia temporal, y que nxml reciba el esquema, ofrezca sus elementos y no pierda un esquema elegido a mano.

En GitHub el paquete se compila con las advertencias tratadas como errores, se revisa con package-lint y se prueba en Linux y Windows con cada cambio, y en macOS con cada versión; en Windows se usa la compilación oficial de GNU, descargada y verificada con su SHA-256. Esas pruebas encontraron los problemas de codificación y el del archivo no confiable. `tools/release.py` repite las pruebas antes de publicar y comprueba que lo que se descarga de Codeberg y GitHub sea lo que subió.

El paquete se probó además instalándolo con `package-vc-install` y con Straight en perfiles vacíos, y sobre la edición latina, de unas 26 000 líneas: la revisión de Flycheck tardó 2,6 segundos, nxml tuvo el esquema 0,7 segundos después y, dentro de un `<rdg>`, ofreció los 123 elementos que el esquema permite allí.

## Plataforma

Necesita Emacs 31.1 o posterior, y funciona en Linux, macOS y Windows, los tres probados en GitHub. Para revisar necesita py-schematron.py con Python 3.15 o posterior y las bibliotecas saxonche y lxml; lo más simple es el instalador de py-schematron, cuyo Python el paquete usa por su cuenta. jing es opcional, para la estructura RelaxNG: en Linux y macOS como orden, en Windows como `jing.jar` con Java. trang, también opcional, le da el esquema a nxml; `tools/install-trang.py` lo descarga, verifica su SHA-1 y lo instala. Flycheck es opcional; sin él se usa Flymake.

Solo necesita internet para descargar los esquemas remotos la primera vez, o al refrescarlos, y para instalar trang. Nunca escribe en los documentos que revisa.

## Ambiente

Fue desarrollado en Fedora Linux 45 con KDE Plasma, con Emacs 31, Python 3.15 y git, y probado en GitHub Actions en Linux, Windows y macOS.

El código está en el repositorio py-schematron.el, publicado en Codeberg (https://codeberg.org/nivaca/py-schematron.el) y en GitHub. Cada versión se etiqueta `vA.B.C` y se publica en las dos forjas con un zip, mediante `tools/release.py`; el historial de cambios está en `CHANGELOG.md`. El paquete es software libre, bajo la GPL, versión 3 o posterior; el software que usa, con la licencia de cada uno, está en `docs/THIRD-PARTY_es.md`.

Se instala desde el repositorio con Straight o con `package-vc-install`, como explica el README; con Straight, por ejemplo, `(use-package py-schematron :straight (:host codeberg :repo "nivaca/py-schematron.el") :hook (nxml-mode . py-schematron-mode))`. `M-x py-schematron-check-setup` dice qué Python, qué jing y qué trang va a usar. Los ajustes son opciones de Customize (`M-x customize-group RET py-schematron`), que se guardan en el archivo de inicio de Emacs. Las conversiones de esquemas para nxml quedan en `~/.emacs.d/py-schematron/`, y los esquemas descargados, en el caché `.schema-cache/` junto a la copia del programa.
