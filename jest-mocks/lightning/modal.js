import { LightningElement } from 'lwc';

// Stand-in for lightning/modal, which @salesforce/sfdx-lwc-jest 7.9.0 does not ship
// (it only has stubs for modalBody, modalFooter and modalHeader).
// It lives outside force-app on purpose, so no deploy ever sees it.
// Only what the components here use: the static open() and close().
// open() resolves to undefined, as when the user dismisses the modal.
export default class LightningModal extends LightningElement {
    static open() {
        return Promise.resolve(undefined);
    }

    close() {}
}
