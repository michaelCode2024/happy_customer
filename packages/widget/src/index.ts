export interface RelayDeskWidgetOptions {
  endpoint: string;
  inboxKey: string;
  externalId?: string;
  displayName?: string;
}

export class RelayDeskWidget extends HTMLElement {
  #options?: RelayDeskWidgetOptions;
  #root = this.attachShadow({ mode: 'open' });

  configure(options: RelayDeskWidgetOptions): void {
    this.#options = options;
  }

  connectedCallback(): void {
    this.#render();
  }

  #render(): void {
    const title = this.getAttribute('title') ?? '在线客服';
    this.#root.innerHTML = `
      <style>
        :host { position: fixed; right: 20px; bottom: 20px; z-index: 2147483000; font-family: system-ui, sans-serif; }
        button { border: 0; border-radius: 999px; padding: 14px 20px; color: white; background: #356ae6; cursor: pointer;
          font: inherit; font-weight: 600; box-shadow: 0 10px 30px rgb(25 55 120 / 25%); }
        button:focus-visible { outline: 3px solid #9bb8ff; outline-offset: 3px; }
      </style>
      <button type="button" aria-label="打开${title}">${title}</button>`;
    this.#root.querySelector('button')?.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('relaydesk:open', { detail: this.#options }));
    });
  }
}

if (!customElements.get('relaydesk-widget')) {
  customElements.define('relaydesk-widget', RelayDeskWidget);
}
