import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { PlatformPage } from './pages/PlatformPage';
import './styles.css';

/**
 * The platform console is a different audience with a different identity and a different
 * token (BR-2.2), so it is chosen here rather than inside App.
 *
 * Two reasons it is not a tab in the tenant console: sharing a shell invites sharing a
 * session, and a conditional return inside a component breaks the rules of hooks — the
 * lint caught that, and the fix it forced is the better structure.
 */
const isPlatformConsole = window.location.pathname.replace(/\/$/, '').endsWith('/platform');

const root = document.getElementById('root');
if (!root) throw new Error('missing #root');

createRoot(root).render(<StrictMode>{isPlatformConsole ? <PlatformPage /> : <App />}</StrictMode>);
