import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Console } from './console/Console';
import './styles.css';

/**
 * The web app is the platform console and nothing else (docs/prototype screens 20–26).
 * Pharmacy owners and staff work in the mobile app.
 */
const root = document.getElementById('root');
if (!root) throw new Error('missing #root');

createRoot(root).render(
  <StrictMode>
    <Console />
  </StrictMode>,
);
