"""Give each released Flutter entrypoint a content address to avoid stale app code."""
import hashlib
from pathlib import Path


def main(root=Path('build/web')):
    code=(root/'main.dart.js').read_bytes()
    name='main.dart.'+hashlib.sha256(code).hexdigest()[:16]+'.js'
    original='"mainJsPath":"main.dart.js"'
    replacement='"mainJsPath":"'+name+'"'
    files=[root/'index.html',root/'flutter_bootstrap.js']
    texts=[path.read_text(encoding='utf-8') for path in files]
    if any(text.count(original)!=1 for text in texts):
        raise ValueError('Unexpected Flutter entrypoint layout; refusing an ambiguous release')
    (root/name).write_bytes(code)
    for path,text in zip(files,texts):
        path.write_text(text.replace(original,replacement),encoding='utf-8')
    print('Versioned web entrypoint:',name)


if __name__=='__main__':
    main()
