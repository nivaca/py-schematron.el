# Registro de cambios

Los cambios notables de py-schematron para Emacs. Las versiones, con sus
archivos zip, están en
[Codeberg](https://codeberg.org/nivaca/py-schematron.el/releases) y
[GitHub](https://github.com/nivaca/py-schematron.el/releases). Hasta la
0.2.0 se publicaban en
[py-schematron](https://codeberg.org/nivaca/py-schematron/releases), como
`emacs-vVERSION`.

## 1.0.2 — 2026-11-23 (py-schematron.py 2.7)

- Donde las categorías Unicode de nxml son las antiguas (bug#82282 de
  Emacs), el paquete las reconstruye ahora con la tabla de la propiedad
  general-category de Emacs, que da el nombre de la categoría de cada
  carácter, como hace characters.el. Lo sugirió el mantenedor de Emacs.
  Las categorías son las mismas de antes; solo el código es más simple.

## 1.0.1 — 2026-11-21 (py-schematron.py 2.7)

- `docs/THIRD-PARTY_es.md` (y `docs/THIRD-PARTY.md`, en inglés): el
  software libre que usa el paquete, y la licencia de cada uno: Emacs,
  Flycheck, Python, saxonche, lxml, jing, trang, las TEI Stylesheets y
  las herramientas con que se prueba. Nada de eso se distribuye con el
  paquete.
- Lleva py-schematron.py 2.7.

## 1.0.0 — 2026-11-19 (py-schematron.py 2.6)

- **Los nombres antiguos desaparecen**, como se anunció en la 0.8.0: las
  opciones y órdenes `py-xmlvalidate-…`, alias obsoletos desde entonces,
  y `py-xmlvalidate.el`, que hacía funcionar `(require 'py-xmlvalidate)`.
  Una configuración que todavía los use debe pasar a los nombres
  `py-schematron` (véase "Moving from py-xmlvalidate" en el README).
- Con esto, los nombres y los ajustes del paquete quedan estables.

## 0.11.0 — 2026-11-19 (py-schematron.py 2.6)

- Las correcciones de los tipos de datos XSD de nxml se aplican ahora al
  activar el modo en un búfer de nxml-mode, antes de que nxml compile el
  esquema para validarlo, y no cuando nxml carga su código XSD: cargar el
  paquete, sin más, no cambia nada en Emacs, como debe ser en un paquete
  (`package-lint` advertía sobre las formas `with-eval-after-load` que lo
  hacían).
- `package-lint` se ejecuta en GitHub con las pruebas; no encuentra nada.
- Trae py-schematron.py 2.6.

## 0.10.1 — 2026-11-19

- **En Windows se revisaba un archivo no confiable.** El backend de
  Flymake dejaba la regla de `trusted-content` a Flymake, que en la
  mayoría de los sistemas no llama a los backends para un archivo no
  confiable, pero en Windows sí; allí se revisaba un documento fuera de
  `trusted-content`, y se ejecutaba su esquema. Ahora el backend mismo
  rechaza ese archivo, como ya hacía el verificador de Flycheck. (Lo
  encontraron las nuevas pruebas en Windows.)

## 0.10.0 — 2026-11-19

- **jing en Windows.** `py-schematron-jing` puede indicar un `jing.jar`,
  que el paquete ejecuta con Java (`java -jar`), o una línea de órdenes
  completa, como lista; si no encuentra el programa, usa el `jing.jar` que
  indique la variable `JING_JAR`. Windows no tiene la orden `jing`, así que
  antes la verificación de RelaxNG no podía ejecutarse allí.
  `M-x py-schematron-check-setup` muestra la orden que usará.
- En Windows, la prueba de un archivo no confiable verifica que no se
  ejecute nada, pues allí Flymake llama al backend en lugar de
  desactivarlo.

## 0.9.3 — 2026-11-19 (py-schematron.py 2.2)

- `M-x py-schematron-trust-file` podía detenerse con "Selecting deleted
  buffer": al iniciar las revisiones de los búferes que vuelve confiables
  pueden cerrarse otros búferes por el camino, los de una revisión
  cancelada. Ahora los salta, y lo mismo hace la recarga del esquema de
  nxml después de una conversión.
- En Windows, las líneas del programa terminan en CR LF; el paquete lee
  ahora su salida con el fin de línea detectado, de modo que el búfer About,
  por ejemplo, ya no muestra `^M` sueltos.

## 0.9.2 — 2026-11-19 (py-schematron.py 2.2)

- **Letras con tilde en Windows.** El paquete leía la salida del programa
  con la página de códigos del sistema, que en Windows no es UTF-8, así
  que todas las letras con tilde de los mensajes, incluidos los de las
  propias reglas, salían estropeadas ("no estÃ¡ bien formado"). Ahora la
  lee como UTF-8, que es lo que escribe py-schematron.py, en las
  revisiones, el informe y los búferes About y de configuración.
- Las pruebas pasan también en Windows y macOS: allí se usa la compilación
  de Emacs para Windows del propio GNU, el pequeño servidor web de una
  prueba se comunica por una tubería, y las carpetas de prueba se borran
  como Windows lo permite.

## 0.9.1 — 2026-11-19 (py-schematron.py 2.2)

- **Los nombres antiguos desaparecerán en la 1.0.** Las opciones y órdenes
  `py-xmlvalidate-…` (alias obsoletos desde la 0.8.0) y `py-xmlvalidate.el`
  se eliminarán en la versión 1.0; una configuración que todavía los use
  debería pasar a los nombres `py-schematron`.
- Las pruebas se ejecutan en GitHub también en Windows con cada push, y en
  macOS para cada versión, además de Linux; dos de ellas ya no suponen un
  sistema Unix.
- Trae py-schematron.py 2.2.

## 0.9.0 — 2026-11-19 (py-schematron.py 2.1)

- **Sin Python que configurar a mano.** py-schematron 2.1 trae un
  instalador para Linux, macOS y Windows que crea un entorno de Python con
  saxonche y lxml. Mientras `py-schematron-python` sea nil, que es ahora su
  valor predeterminado, el paquete usa el Python de ese entorno si está
  instalado, y `python3` si no. Un valor ya fijado sigue funcionando como
  antes.
- Los pasos de configuración (*Before you start*) empiezan con el
  instalador; un entorno virtual propio queda como alternativa. Los
  mensajes de error sobre Python también remiten al instalador.
- Trae py-schematron.py 2.1.

## 0.8.0 — 2026-11-19 (py-schematron.py 2.0)

- **El paquete pasa a llamarse py-schematron** (era py-xmlvalidate), igual
  que el programa, ahora py-schematron. Su repositorio es
  nivaca/py-schematron.el, en Codeberg y GitHub; las direcciones antiguas
  redirigen a él. Con Straight:

  ```elisp
  (use-package py-schematron
    :straight (:host codeberg :repo "nivaca/py-schematron.el" :depth 1)
    :hook (nxml-mode . py-schematron-mode))
  ```

  Todas las opciones y órdenes son ahora `py-schematron-…`. Los nombres
  antiguos siguen funcionando por ahora como alias obsoletos, y `(require
  'py-xmlvalidate)` carga el paquete, de modo que una configuración
  anterior todavía funciona, con advertencias. La caché de los esquemas de
  nxml se traslada a `~/.emacs.d/py-schematron/`; la antigua carpeta
  `py-xmlvalidate/` puede borrarse. El instalador de trang reconoce un
  envoltorio que instaló con el nombre antiguo.
- Trae py-schematron.py 2.0.

## 0.7.0 — 2026-11-19 (py-xmlvalidate.py 1.21)

- **Dos errores más de nxml, remediados**, cada uno solo donde el Emacs en
  uso lo tiene. Las categorías Unicode de nxml son de Unicode 3.1 y se
  detienen en U+FFFF, así que rechazaba las abreviaturas medievales `ꝑ` y
  `ꝯ`, y letras CJK, góticas y otras, en `teidata.name` y `teidata.word`
  de TEI; el paquete las reconstruye a partir de los datos Unicode del
  propio Emacs, con cachés, para que nxml no se vuelva más lento. Y los
  valores `xsd:token` conservaban un espacio en cada extremo, de modo que
  `ed=" #U2"` no pasaba `teidata.word`.
- Las correcciones se aplican ahora en cuanto nxml carga su código XSD, no
  cuando el paquete le da a nxml un esquema por primera vez, así que valen
  también para un esquema elegido por uno mismo. La nueva opción
  `py-xmlvalidate-fix-nxml` las desactiva, y `M-x py-xmlvalidate-about`
  enumera lo que se remedió.
- `upstream/` tiene los cuatro errores de nxml redactados para el gestor de
  errores de Emacs, cada uno con una receta a partir de `emacs -Q`.

## 0.6.0 — 2026-11-19 (py-xmlvalidate.py 1.21)

- El paquete ya no lee los mensajes en español del programa en stderr: los
  errores fatales del programa salen de su JSON, palabra por palabra, y
  *el esquema se descargó de nuevo* sale de los eventos del informe. Con
  un `py-xmlvalidate.py` anterior (indicado en `py-xmlvalidate-script`),
  stderr se sigue leyendo como antes.
- **`M-x py-xmlvalidate-goto-rule`** abre el esquema en la regla que está
  detrás del error de Schematron de la línea actual: el assert o report que
  lo informó, en el ODD o el RelaxNG del que salió (el archivo que se
  edita, no el `.sch` generado a partir de él). Si hay varias, pregunta
  cuál; `M-,` regresa. Funciona con Flymake y con Flycheck. Requiere
  py-xmlvalidate.py 1.21, que dice dónde está cada regla.
- La corrección del error de puntuación de nxml se aplica solo cuando el
  Emacs en uso tiene el error: el paquete le da primero a
  `xsdre-range-list-union` dos listas nuevas y mira si las modifica.
  Cuando Emacs lo corrija, el paquete dejará en paz a nxml, sin que haga
  falta cambiar nada aquí.
- Las pruebas se ejecutan en GitHub también cada lunes.

## 0.5.1 — 2026-11-18 (py-xmlvalidate.py 1.20)

- **El error de puntuación de nxml se remedia en su causa.** nxml
  rechazaba `#`, `%`, `!`, `@`, `¿` y otros en valores que el esquema
  permite, porque construir `\p{P}` (o `\p{S}`, `\p{C}`) estropea la tabla
  que nxml guarda en caché de la última categoría que contiene:
  `xsdre-range-list-union` combina las listas en el sitio, y `append` no
  copia la última. Ahora el paquete hace que nxml las copie primero (un
  advice, que se pone la primera vez que le da a nxml un esquema y se quita
  al descargarlo), en lugar de ampliar el patrón de palabra de TEI en la
  copia del esquema de nxml, lo que solo corregía ese patrón. La copia de
  nxml es ahora exactamente la que hace trang.
- Trae py-xmlvalidate.py 1.20, cuya opción `-o` encuentra las TEI
  Stylesheets mediante `--stylesheets`, `TEI_STYLESHEETS` o la
  configuración de ODD2RNG. `M-x py-xmlvalidate-about` muestra qué carpeta
  usa.
- Las pruebas se ejecutan en GitHub con cada push (compilación a bytecode
  con las advertencias tratadas como errores, y luego las pruebas ERT con
  Flycheck, jing y trang), y `tools/release.py` publica una versión con
  una sola orden.

## 0.5.0 — 2026-11-18 (py-xmlvalidate.py 1.19)

- `M-x py-xmlvalidate-about` muestra qué es el paquete: su versión, autor,
  licencia y enlaces (en los que se puede hacer clic), el verificador en
  uso, y lo que su copia de `py-xmlvalidate.py` dice de sí misma (su nueva
  opción `--about`: la versión del programa, y el Python y las bibliotecas
  con que se ejecuta).

## 0.4.0 — 2026-11-18 (py-xmlvalidate.py 1.18)

- `M-x py-xmlvalidate-recreate-nxml-schema` vuelve a convertir para nxml,
  de inmediato, el esquema RelaxNG del documento, y lo recarga en todos los
  búferes que lo usan. Cuando no puede ejecutarse, explica por qué (no hay
  trang, el archivo está fuera de `trusted-content`, el esquema se eligió a
  mano, el esquema no es RelaxNG).
- `py-xmlvalidate-report` termina con "incomplete" cuando py-xmlvalidate.py
  sale con 3: desde la 1.18 lo hace cuando una regla no pudo evaluarse,
  además de con un documento mal formado.
- Corrección: cuando el archivo RelaxNG cambiaba, la copia compacta se
  volvía a convertir, pero los búferes que ya la usaban conservaban la
  copia antigua de nxml hasta que se reabrían, porque el nombre del archivo
  no cambia. Ahora todos los búferes que la usan la recargan.

## 0.3.0 — 2026-11-18 (py-xmlvalidate.py 1.17)

- El paquete tiene un repositorio propio, py-xmlvalidate-emacs, y trae su
  propia copia de `py-xmlvalidate.py`, junto a `py-xmlvalidate.el`. Las
  recetas son más sencillas: Straight no necesita `:files`, ni package-vc
  `:lisp-dir`. Las recetas que apuntan a py-xmlvalidate dejan de funcionar,
  porque su carpeta `emacs/` ya no existe; véase "Moving from the
  py-xmlvalidate repository" en el README.
- `tools/install-trang.py` se trasladó aquí con el paquete.
- La historia del paquete vino con él, y sus etiquetas pasaron de
  `emacs-vVERSION` a `vVERSION`.

## 0.2.0 — 2026-11-17

- Flycheck: un verificador además del backend de Flymake;
  `py-xmlvalidate-frontend` elige, y `auto` usa Flycheck si está instalado.
  El paquete aplica por sí mismo la regla de `trusted-content`, ya que
  Flycheck no tiene ninguna.
- nxml-mode recibe el esquema RelaxNG del documento, convertido a la
  sintaxis compacta con trang y guardado en caché, para que `C-RET`
  complete lo que el esquema permite y nxml valide la estructura. Un
  esquema elegido a mano nunca se reemplaza, y no se escribe nada junto al
  documento. Las tablas de nxml para `\p{P}` y `\p{S}` dejan fuera la
  puntuación ASCII, así que en su copia el patrón de palabra de TEI
  enumera también esos caracteres.
- `tools/install-trang.py` descarga trang, verifica su SHA-1 y lo instala
  en `~/bin` (o en `~/.local/bin`).

## 0.1.2 — 2026-11-17

- Es difícil pasar por alto un archivo fuera de `trusted-content`: una
  advertencia, una vez por archivo, con la línea que hay que añadir al
  archivo de inicio; `py-xmlvalidate-check` y
  `py-xmlvalidate-refresh-schema` explican por qué no pueden ejecutarse; el
  informe termina con una nota.
- `M-x py-xmlvalidate-trust-file` vuelve confiable el archivo o su carpeta,
  tras preguntar, durante la sesión, y pone en el kill ring la línea que lo
  hace permanente.

## 0.1.1 — 2026-11-17

- Se instala con Straight: el paquete sigue el enlace a su propio archivo
  hasta el clon de Straight para encontrar `py-xmlvalidate.py`.

## 0.1.0 — 2026-11-17

- Primera versión: un backend de Flymake que revisa búferes XML/TEI contra
  sus reglas de Schematron mientras se escribe, a partir de una copia
  temporal privada, con jing para los esquemas RelaxNG; órdenes para
  revisar, actualizar un esquema remoto, ver el informe completo, revisar
  la configuración y ver el registro.
