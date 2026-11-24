# Diccionario de datos — Fuente sintética

**I.E.P. N° 1217 "Jorge Basadre Grohmann"** — Chaclacayo, UGEL 06 Ate-Vitarte
Nivel **Secundaria** (EBR, ciclos VI y VII), jornada escolar regular.
Año escolar **2025 completo** (clases del 17/03 al 19/12) y **2026 hasta el 15
de setiembre** (clases desde el 16/03; I y II bimestre cerrados, III en curso).

> Todos los DNI, códigos modulares, nombres, direcciones y teléfonos son
> **ficticios**, generados para fines académicos.

**145,000 filas en 17 archivos**, delimitador `;`, UTF-8, fin de línea `0x0a`.

---

## Dos versiones del mismo dato, a propósito

| Qué | Dónde | Estado |
|---|---|---|
| **Origen crudo** | carpeta `data/` (CSV) | **Sucio**: 94 tipos de defecto, 7,007 registros afectados |
| **Resultado esperado** | `DataMart_IE1217_Secundaria.xlsx` | Limpio, consolidado, con KPIs |

La diferencia entre ambos es el trabajo de la capa de transformación del
diagrama. El archivo `data/_catalogo_defectos.csv` y la hoja **Control_Calidad**
del libro listan cada defecto con su conteo exacto y la regla SQL que debe
detectarlo; `02_diagnostico_calidad.sql` los cuantifica sobre el staging.

---

## La nota: número en el origen, letra calculada

El docente registra en su **registro auxiliar en escala vigesimal (0 a 20)** y
recién al reportar al SIAGIE se convierte a la escala literal del CNEB. Por eso
el origen trae `NotaVigesimal` y la letra **no se almacena: se calcula**.

| Nota | Nivel | Descripción |
|---:|:--:|---|
| 0 – 10 | **C** | En inicio |
| 11 – 13 | **B** | En proceso |
| 14 – 17 | **A** | Logro esperado |
| 18 – 20 | **AD** | Logro destacado |

En el libro esa tabla vive en la hoja **Escala** (celdas amarillas, las únicas
editables). Las hojas `Notas_Competencia` y `Notas_Area` la consultan con
`INDEX`/`MATCH`: si cambian un umbral ahí, las celdas de letra se
recalculan solas. El libro tiene 125,115 fórmulas y recalcula sin errores.

**Grano.** No se asigna nivel de logro a cada área: el docente solo registra el
de **cada competencia**. El calificativo del área se deriva promediando las
notas de sus competencias y convirtiendo ese promedio a letra.

**Plan de estudios.** Jornada regular: 31 horas obligatorias + 2 de tutoría +
2 de libre disponibilidad. Las 10 áreas evaluadas suman exactamente 31.

---

## La matrícula sigue el cronograma oficial del Minedu

Las fechas no son aleatorias: caen dentro de las ventanas publicadas para el
proceso regular de matrícula.

| Fase | Año escolar 2025 | Año escolar 2026 |
|---|---|---|
| Presentación de solicitudes | 16 dic 2024 – 3 ene 2025 | 2 – 11 ene 2026 |
| Revisión de solicitudes | 6 – 17 ene 2025 | 12 – 18 ene 2026 |
| Asignación de vacantes | 20 – 28 ene 2025 | 19 – 30 ene 2026 |
| Registro en SIAGIE | 29 ene – 12 feb 2025 | 31 ene – 4 feb 2026 |
| Inicio de clases | 17 mar 2025 | 16 mar 2026 |

**Dos vías distintas, como manda la norma.** Quien continúa en el mismo colegio
no repite la inscripción: el apoderado solo comunica la continuidad al
director. Por eso el archivo distingue:

- `Solicitud de vacante` — ingresantes y traslados. Recorren las cuatro fases,
  con sus cuatro fechas.
- `Ratificación de continuidad` — continuadores y repitentes. Sus tres primeras
  fechas van **vacías a propósito**: no es un dato faltante, es que no les
  corresponde ese trámite.

Un 7% de las solicitudes se atiende en la **fase complementaria**, la ventana
posterior para quienes no alcanzaron vacante en la regular.

### El estado tiene solo dos valores

`EstadoMatricula` es **Aprobado** o **Rechazado**, y nada más. La columna
`Observacion` se llena únicamente cuando fue rechazada, con el motivo:
documentación incompleta, DNI que no valida en RENIEC, no se presentó a la
entrega de documentos, duplicidad en SIAGIE, sin vacante disponible.

Y una regla que el modelo respeta: **una matrícula rechazada no genera
asistencia, ni notas, ni casos de convivencia.** Ese estudiante nunca cursó el
año en la institución. Verificado: cero registros académicos de rechazados.

### El aforo de 30 es un techo duro

Cada sección tiene 30 vacantes y ninguna las excede. Cuando un grado se llena
con repitentes y promovidos, al excedente no le alcanza vacante y su matrícula
se rechaza con ese motivo — así el motivo "Sin vacante disponible" responde a
una restricción real del modelo y no es decorativo. La ocupación resultante es
de 96% en ambos años.

Nota sobre dos detalles: el oficio del Minedu cierra la asignación de vacantes
2026 el 21 de enero, pero se usó la ventana del 19 al 30 por ser más amplia y
contener a la otra. Y las fechas de la fase complementaria 2025 son una
aproximación análoga a las de 2026, porque solo se ubicó el calendario regular
de ese año.

---

## El material educativo del Estado

El Minedu distribuye por UGEL, para cada área y grado de secundaria, un **texto
escolar** (retornable) y un **cuaderno de trabajo** (fungible, el estudiante
escribe en él). Los títulos del catálogo son los reales de las series que
imprime el Estado:

| Área | Texto escolar | Cuaderno de trabajo |
|---|---|---|
| Matemática | Matemática 1–5 | **Resolvamos problemas** 1–5 |
| Comunicación | Comunicación 1–5 | **Comprensión lectora** 1–5 |
| Ciencia y Tecnología | Ciencia y Tecnología 1–5 | **Fichas de autoaprendizaje** 1–5 |
| Ciencias Sociales | Ciencias Sociales 1–5 | **Cuaderno de fichas Fuentes históricas** 1–5 |
| DPCC | Desarrollo Personal, Ciudadanía y Cívica 1–5 | Cuaderno de trabajo de DPCC 1–5 |

Inglés, Arte y Cultura, Educación para el Trabajo, Educación Física y Educación
Religiosa quedan fuera del catálogo: no se logró confirmar un título oficial
vigente para esas áreas, y se prefirió dejarlas fuera antes que inventar un
nombre. Por eso sus docentes aparecen con cero ejemplares en la ficha.

**El circuito modelado.** El colegio recibe la dotación **dos semanas antes del
inicio de clases** (3 de marzo de 2025, 2 de marzo de 2026) y debe entregarla a
los estudiantes **el primer día**. El docente de cada área responde por la
entrega en sus secciones.

`entrega_materiales.csv` tiene grano de material × sección × año, con las tres
cantidades que pide el negocio:

- `CantidadPorEntregar` — los matriculados aprobados de esa sección
- `CantidadEntregadaATiempo` — recibieron su ejemplar el primer día
- `CantidadEntregadaDestiempo` — lo recibieron después, sea porque el docente
  se demoró o porque el estudiante faltó ese día
- `CantidadNoEntregada` — la UGEL despachó menos ejemplares de los necesarios

Y se cumple siempre: **a tiempo + destiempo + no entregada = por entregar**.
Esa es la regla madre de la tabla; si no cuadra, cualquier porcentaje de
cobertura sale falso.

Resultado: 62% de entrega oportuna en 2025 y 70% en 2026, con cobertura total
de 98% y 99%. El peor retraso registrado es de 21 días.

Ojo con una confusión posible: las columnas `RecursosProgramados` y
`RecursosUtilizados` de `sesiones.csv` son **otra cosa** — los recursos que el
docente planificó usar en una clase puntual. Las renombré justamente para que
no se mezclen con la dotación oficial.

---

## Archivos

### Catálogos (limpios)

| Archivo | Filas | Contenido |
|---|---:|---|
| `institucion.csv` | 1 | Código modular, DRE, UGEL, ubigeo, turno, jornada |
| `materiales.csv` | 50 | Catálogo de textos escolares y cuadernos de trabajo por área y grado |
| `areas_curriculares.csv` | 11 | 10 áreas evaluadas + tutoría, con horas |
| `competencias.csv` | 28 | 26 específicas + 2 transversales |
| `personal.csv` | 7 | Director, subdirectora, TOE, psicólogo, auxiliares |
| `secciones.csv` | 20 | 5 grados × 2 secciones × 2 años |
| `carga_horaria.csv` | 220 | Cuadro de distribución de horas |

### Con defectos

| Archivo | Filas | Tipos | Registros afectados |
|---|---:|---:|---:|
| `estudiantes.csv` | 373 | 27 | 501 |
| `docentes.csv` | 15 | 7 | 29 |
| `apoderados.csv` | 368 | 5 | 64 |
| `matricula.csv` | 615 | 13 | 322 |
| `asistencia.csv` | 91,126 | 6 | 2,825 |
| `notas_competencias.csv` | 45,396 | 11 | 2,100 |
| `sesiones.csv` | 6,425 | 8 | 792 |
| `monitoreo_docente.csv` | 88 | 3 | 19 |
| `convivencia.csv` | 736 | 6 | 185 |
| `entrega_materiales.csv` | 200 | 9 | 276 |

---

## Los defectos, por categoría

**Estandarización — 23 tipos, 2,973 registros.** Sexo escrito de seis formas
(`M`, `m`, `Masculino`, `MASCULINO`, `1`, `H`), fechas en cinco formatos,
distrito con mayúsculas y tildes, notas con coma decimal (`15,0`) porque es el
default de Excel en español, notas con cero a la izquierda (`07`).

**Limpieza — 13 tipos, 1,349 registros.** Aquí está lo humano. Errores de
tipeo por transposición, letra doblada o tecla vecina: `Asisitio`, `Tardansa`,
`Falta injustifcada`, `Dictadda`, `Nombrrado`, `Ingresente`, `Atendio`.
Dobles espacios dentro de los nombres. Tabuladores al final de la dirección.
Caracteres corruptos (`Ã±` donde va `ñ`) por archivo guardado en ANSI.

Ninguna normalización por mayúsculas arregla un typo: `Dictadda` simplemente
no entra en el conteo de sesiones dictadas y el KPI sale bajo sin explicación.

**Validación — 16 tipos, 1,103 registros.** DNI de 7 dígitos porque Excel se
comió el cero, fechas como `31/02/2011`, notas de `25` o `-3`, notas escritas
como `QUINCE`, minutos de retraso negativos, rúbricas con puntaje 5 en escala
de I a IV.

Un caso especial: **380 competencias sin nota**, con el comentario
predeterminado que la norma permite cuando el docente no reunió evidencia
suficiente. **Eso no es un error**: es un registro válido que debe excluirse
del cálculo, no contarse como desaprobado.

Y otro que vale la pena mirar: **150 registros donde el docente escribió la
letra (`A`, `AD`) en la columna de la nota**. El ETL debería aceptar ambas
escalas en vez de descartarlos.

**Integridad — 17 tipos, 937 registros.** 320 asistencias duplicadas que
inflan el porcentaje, 260 competencias calificadas dos veces, 9 dobles
matrículas del mismo estudiante en el mismo año, códigos con letra `O` en
lugar de cero, y huérfanos varios.

El peor del lote: **89 claves con espacio no separable (CHAR 160)**. `TRIM()`
**no lo elimina**. El código se ve idéntico en pantalla, pasa cualquier
inspección visual, y el `JOIN` devuelve menos filas sin dar un solo error. La
limpieza correcta de una clave es:

```sql
LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(col, NCHAR(160), N''), CHAR(9), N''), CHAR(13), N'')))
```

**Coherencia — 16 tipos, 477 registros.** Aquí entran los tres defectos nuevos
ligados al cronograma: 22 solicitudes registradas **fuera de la ventana
oficial**, 16 registros en SIAGIE con fecha anterior a la solicitud, y 13
continuadores con solicitud de vacante cuando no les corresponde.

También dos sobre el nuevo estado: 12 matrículas aprobadas que traen texto en
`Observacion` cuando debería ir vacía, y 9 rechazadas sin motivo registrado.

Además: discapacidad marcada sin tipo, docente nombrado sin escala magisterial,
materiales utilizados mayores que los programados, sesión no dictada sin
motivo, puntaje total que no cuadra con la suma de rúbricas, caso atendido sin
fecha de atención, y 7 filas con el nombre y el apellido intercambiados de
columna.

---

## Lo que hace que la data tenga sentido

Bajo el ruido hay estructura. Variables latentes por estudiante (aptitud,
contexto) y por docente (efectividad) generan correlaciones verificables:

| Relación | Correlación |
|---|---:|
| % de inasistencia ↔ nivel de logro | **−0.48** |
| Puntaje de monitoreo del docente ↔ logro de sus estudiantes | **+0.53** |
| Casos de convivencia ↔ nivel de logro | **−0.63** |

**Coherencia de cohorte:** 220 estudiantes aparecen en ambos años con el mismo
código — 195 promovidos, 25 repitentes; los 56 de quinto egresaron y ninguno
reaparece.

**Distribuciones:** A 43% · B 33% · C 13% · AD 11% a nivel de área. Aprobación de matrícula 96%, ocupación de vacantes 96%, asistencia 91%.
Asistencia 91%. Matemática concentra el mayor porcentaje de C, reproduciendo
el patrón real del sistema peruano.

---

## Carga

1. Copiar `data/` a `C:\BI_IE1217\data`
2. Dar permiso de lectura a `NT Service\MSSQLSERVER` sobre esa carpeta
3. `01_staging_secundaria.sql` — crea la base, el staging y carga los 15 archivos
4. `02_diagnostico_calidad.sql` — perfila el origen y cuantifica cada defecto,
   incluido un bloque que verifica fase por fase el cumplimiento del cronograma

El último bloque del diagnóstico compara el KPI de cumplimiento de horarios
calculado sin limpiar contra el calculado con limpieza. Esa diferencia es el
argumento entero a favor de tener capa de calidad.
