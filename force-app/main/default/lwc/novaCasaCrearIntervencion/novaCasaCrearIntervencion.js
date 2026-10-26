import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import crearIntervencion from '@salesforce/apex/IntervencionOperadorController.crearIntervencion';
import { reduceError } from 'c/novaCasaEtiquetas';

// IntervencionOperadorController.MOTIVO_MAX
const MOTIVO_MAX = 1000;

// Manual intervention in the layout of a native "New record" dialog. Not the native Case form: the operator has no Create
// on Case, and crearIntervencion checks the permission, the readings and that no intervention is open, and sets the
// priority from the current severity (D020). The fields above the reason only show what the server will do.
export default class NovaCasaCrearIntervencion extends LightningModal {
    @api assetId;
    @api assetName;
    @api buildingName;
    @api severityKey;
    @api severityLabel;
    @api severityGlyph;
    @api readingText;
    @api priorityLabel;

    motivo = '';
    saving = false;
    errorMessage = '';
    motivoMax = MOTIVO_MAX;

    get sevClass() {
        return `sev sev-${this.severityKey || 'nivel'}`;
    }
    get buildingText() {
        return this.buildingName || '—';
    }
    get readingDisplay() {
        return this.readingText || '—';
    }
    get counterText() {
        return `${this.motivo.length} / ${MOTIVO_MAX}`;
    }
    get saveDisabled() {
        return this.saving || !this.motivo.trim();
    }

    handleMotivo(event) {
        this.motivo = event.target.value || '';
    }

    handleCancel() {
        this.close(null);
    }

    async handleSave() {
        const field = this.template.querySelector('lightning-textarea');
        if (field && !field.reportValidity()) {
            return;
        }
        if (this.saveDisabled) {
            return;
        }
        this.saving = true;
        this.disableClose = true;
        this.errorMessage = '';
        try {
            const result = await crearIntervencion({ assetId: this.assetId, motivo: this.motivo });
            this.disableClose = false;
            this.close({ caseId: result.caseId, caseNumber: result.caseNumber });
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.saving = false;
            this.disableClose = false;
        }
    }
}
