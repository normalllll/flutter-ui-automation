"""Public fixture entrypoint; platform implementations are imported on demand."""
import sys
from lab_cli import main

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
