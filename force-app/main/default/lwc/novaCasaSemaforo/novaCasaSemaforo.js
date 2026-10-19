import { LightningElement, api } from 'lwc';
import { severityUi } from 'c/novaCasaEtiquetas';

function toLevel(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    const level = Number(value);
    return level === 0 || level === 1 || level === 2 ? level : null;
}

// Three-lamp traffic light for a severity level (D042). Only the current lamp is lit and carries its glyph, so the
// level never depends on color alone; the severity pill with text stays next to it.
export default class NovaCasaSemaforo extends LightningElement {
    /** Severity level 2, 1 or 0; null means no level. */
    @api nivel;
    /** vertical (red on top) or horizontal (red on the left). */
    @api orientacion = 'vertical';
    /** Smaller lamps, for table rows. */
    @api compacto = false;
    /** Label of the no-level state, so it matches the pill next to it ("Sin dato" or "Sin lecturas"). */
    @api etiquetaSinDato;
    /** Added to the accessible label when the level may be incomplete, e.g. "(lecturas incompletas)". */
    @api sufijo;

    get level() {
        return toLevel(this.nivel);
    }
    get isCritical() {
        return this.level === 2;
    }
    get isWarning() {
        return this.level === 1;
    }
    get isStable() {
        return this.level === 0;
    }
    get isUnknown() {
        return this.level === null;
    }

    get housingClass() {
        let cls = this.orientacion === 'horizontal' ? 'caja horizontal' : 'caja';
        if (this.compacto) {
            cls += ' compacto';
        }
        if (this.isUnknown) {
            cls += ' sin-dato';
        }
        return cls;
    }
    get redClass() {
        return this.isCritical ? 'luz roja encendida' : 'luz roja';
    }
    get amberClass() {
        return this.isWarning ? 'luz ambar encendida' : 'luz ambar';
    }
    get greenClass() {
        return this.isStable ? 'luz verde encendida' : 'luz verde';
    }

    get ariaLabel() {
        const label = this.isUnknown && this.etiquetaSinDato ? this.etiquetaSinDato : severityUi(this.level).label;
        return this.sufijo ? `Semáforo: ${label} ${this.sufijo}` : `Semáforo: ${label}`;
    }
}
