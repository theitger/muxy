import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { german } from './lib/i18n'
import App from './App.tsx'

document.documentElement.lang = german ? 'de' : 'en'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
