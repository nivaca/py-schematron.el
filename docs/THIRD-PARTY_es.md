Software libre que usa py-schematron.el
=======================================

py-schematron.el es software libre, bajo la Licencia Pública General de
GNU, versión 3 o posterior (GPL-3.0-or-later).  El paquete lo forman solo
sus propios archivos: `py-schematron.el` y una copia de `py-schematron.py`,
de [py-schematron](https://github.com/nivaca/py-schematron), del mismo
autor y con la misma licencia.  Ninguno de los programas de abajo está
copiado en este repositorio ni en el zip de las versiones; cada uno se
instala aparte y conserva su licencia.

Con qué corre el paquete
------------------------

| Software | Para qué se usa | Licencia |
|---|---|---|
| [GNU Emacs](https://www.gnu.org/software/emacs/) 31.1 o posterior, con las bibliotecas que incluye (Flymake, nxml-mode, `xsd-regexp`, `rng-xsd`, `compile`, `xref`, `cl-lib`, `seq`, `lisp-mnt`) | El editor, y el backend de Flymake, el esquema de nxml y el resto del paquete | GPL-3.0-or-later |
| [Flycheck](https://www.flycheck.org/) (opcional) | El verificador que se usa en lugar de Flymake cuando Flycheck está instalado | GPL-3.0-or-later |
| [Python](https://www.python.org/) 3.15 o posterior, con su biblioteca estándar | Ejecuta `py-schematron.py` | Python Software Foundation License (PSF-2.0) |
| [saxonche](https://pypi.org/project/saxonche/) (SaxonC-HE, de Saxonica) | Evalúa las reglas Schematron con XPath 3.1, en `py-schematron.py` | Mozilla Public License 2.0 (MPL-2.0) |
| [lxml](https://lxml.de/) | Halla la línea y el `xml:id` de cada infracción, en `py-schematron.py` | BSD-3-Clause |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) y [libxslt](https://gitlab.gnome.org/GNOME/libxslt) | Las bibliotecas en C bajo lxml (incluidas en sus wheels) | MIT |
| [jing](https://relaxng.org/jclark/jing.html), de James Clark (opcional) | Revisa la estructura RelaxNG | BSD-3-Clause (Thai Open Source Software Center) |
| [trang](https://relaxng.org/jclark/trang.html), de James Clark (opcional) | Convierte el esquema RelaxNG a la sintaxis compacta para nxml (`py-schematron-nxml-schema`); `tools/install-trang.py` lo descarga del proyecto [jing-trang](https://github.com/relaxng/jing-trang) | BSD-3-Clause (Thai Open Source Software Center) |
| Un entorno de Java, como [OpenJDK](https://openjdk.org/) (solo con jing o trang) | Ejecuta jing y trang | GPL-2.0 con la Classpath Exception (OpenJDK) |
| [TEI Stylesheets](https://github.com/TEIC/Stylesheets): `odds/extract-isosch.xsl` y `common/functions.xsl` (solo para esquemas ODD) | Extraen las reglas Schematron de un ODD, en `py-schematron.py`.  No se distribuyen con el paquete | Doble licencia: BSD-2-Clause o Creative Commons Atribución-CompartirIgual 3.0 (CC-BY-SA-3.0), a elección del usuario |

El jing que distribuye su proyecto (un `jing.jar`, como en Windows) trae
algunas bibliotecas propias, como Xerces y Saxon 9; sus licencias están en
la carpeta `doc/` de esa distribución.

Con qué se desarrolla y se prueba
---------------------------------

Nada de esto hace falta para usar el paquete, y nada se distribuye con él.

| Software | Para qué se usa | Licencia |
|---|---|---|
| ERT (parte de GNU Emacs) | Las pruebas de `test/py-schematron-tests.el` | GPL-3.0-or-later |
| [package-lint](https://github.com/purcell/package-lint) | Revisa las cabeceras y las convenciones del paquete, en las pruebas de GitHub | GPL-3.0-or-later |
| [GitHub Actions](https://github.com/features/actions): `actions/checkout`, `actions/setup-python`, [`purcell/setup-emacs`](https://github.com/purcell/setup-emacs) | Ejecutan las pruebas en Linux, macOS y Windows | MIT |
