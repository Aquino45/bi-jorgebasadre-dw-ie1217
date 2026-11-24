# Datos de origen (sintéticos)

Los 17 CSV de esta carpeta fueron **generados con IA** para el curso de Business Intelligence (UPeU). Los DNI, códigos, nombres, direcciones, teléfonos, notas y registros son **ficticios**: no corresponden a estudiantes, apoderados, docentes ni personal reales de la I.E. N° 1217. Cualquier coincidencia con una persona real es casual.

- Formato: delimitador `;`, UTF-8 sin BOM, fin de línea LF. No abrir y guardar con Excel: cambia el formato y las huellas.
- Traen defectos a propósito (duplicados, fechas en varios formatos, textos mal escritos): limpiarlos es el trabajo del ETL.
- El detalle de cada archivo está en `00_DICCIONARIO_DE_DATOSv5.md`.
- El ETL no lee esta carpeta: lee `C:\BI_IE1217\data`. El instalador del repositorio copia los CSV ahí.
