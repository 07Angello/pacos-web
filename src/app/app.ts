import { Component, inject, OnInit } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { LicenseService } from './core/license.service';
import { VisitorTrackerService } from './core/visitor-tracker.service';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet],
  template: `
    @if (license.blocked()) {
      <main class="fixed inset-0 z-[100] grid place-items-center bg-cream-50 px-6 text-center" role="alertdialog" aria-labelledby="lic-title" aria-describedby="lic-msg">
        <div class="max-w-md animate-fade-in">
          <span class="mx-auto grid size-20 place-items-center rounded-3xl bg-ink-900 text-3xl text-white"><i class="fa-solid fa-lock"></i></span>
          <h1 id="lic-title" class="mt-6 text-2xl font-extrabold">Servicio no disponible</h1>
          <p id="lic-msg" class="mt-3 whitespace-pre-line leading-relaxed text-ink-700">{{ license.message() }}</p>
          <button type="button" class="btn btn-ghost mt-8" (click)="license.refresh()"><i class="fa-solid fa-rotate"></i> Reintentar</button>
        </div>
      </main>
    } @else {
      <router-outlet />
    }
  `,
})
export class App implements OnInit {
  protected readonly license = inject(LicenseService);
  private readonly visitors = inject(VisitorTrackerService);

  ngOnInit(): void {
    this.license.start();
    this.visitors.start();
  }
}
