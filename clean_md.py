import re
import os

def clean_file(filepath):
    if not os.path.exists(filepath):
        return
        
    with open(filepath, 'r') as f:
        content = f.read()

    # 1. Remove the Free vs Pro section completely (stops at the next ## header)
    content = re.sub(r'## 🆓 (?:2\. Modelo Freemium y Funcionalidades \(Free vs ⭐ Pro\)|Free vs ⭐ Pro)\n.*?(?=\n## |\Z)', '', content, flags=re.DOTALL)

    # 2. Remove the "Sistema de Licencias" sections
    content = re.sub(r'### 🔑 Sistema de Licencias.*?(?=\n### |\Z)', '', content, flags=re.DOTALL)
    content = re.sub(r'### Activar LCC Pro.*?(?=\n### |\Z)', '', content, flags=re.DOTALL)
    
    # 3. Remove "Free Tier" and "LCC Pro" badges
    content = re.sub(r'!\[.*?\]\(https://img\.shields\.io/badge/Free%20Tier.*?\)\n?', '', content)
    content = re.sub(r'!\[.*?\]\(https://img\.shields\.io/badge/LCC%20Pro.*?\)\n?', '', content)

    # 4. Modify feature badges to remove "Pro" and "Free"
    content = re.sub(r'-Pro-[a-z]+', '-Available-blue', content)
    content = re.sub(r'-Free-[a-z]+', '-Available-green', content)

    # 5. Remove ' ⭐ Pro', ' — Free', ' (Pro)' from headers and list items
    content = re.sub(r' ⭐ Pro', '', content)
    content = re.sub(r' — Free', '', content)
    content = re.sub(r' \(Pro\)', '', content)
    content = re.sub(r' \(requiere Pro\)', '', content)
    content = re.sub(r' — requiere Pro', '', content)
    
    # 6. Remove specific text references
    content = re.sub(r', ilimitados en Pro, 1 en Free', '', content)
    content = re.sub(r'La versión gratuita cubre los casos de uso esenciales; \*\*LCC Pro\*\* desbloquea todas las funciones avanzadas\.', '', content)
    content = re.sub(r'o adquirir \*\*LCC Pro\*\*', '', content)
    content = re.sub(r'\(Pro\)', '', content)
    content = re.sub(r'- \[x\] Modelo Freemium/Pro con licencias Ed25519\n', '', content)

    with open(filepath, 'w') as f:
        f.write(content)

clean_file('README.md')
clean_file('docs/SSOT.md')
print("Done formatting README and SSOT.")
