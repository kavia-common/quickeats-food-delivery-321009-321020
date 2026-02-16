#!/bin/bash

# Minimal PostgreSQL startup script with full paths
# Enhanced with idempotent QuickEats schema + seed initialization.
#
# NOTE: Per project rules, schema/seed is applied via psql -c one statement at a time
# (no new .sql files), and the state is tracked in a simple schema_migrations table.

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# -----------------------------
# Helpers
# -----------------------------

# PUBLIC_INTERFACE
run_psql() {
    """Run a single SQL statement via psql using the connection string in db_connection.txt."""
    # Uses ON_ERROR_STOP to fail fast if a statement is invalid.
    # Intentionally executes ONE statement per call to follow the PostgreSQL container rules.
    local sql="$1"
    local conn
    conn="$(cat db_connection.txt)"
    ${conn} -v ON_ERROR_STOP=1 -c "${sql}"
}

# PUBLIC_INTERFACE
ensure_quickeats_schema_and_seed() {
    """Create QuickEats schema + seed idempotently, tracking completion in schema_migrations."""
    echo "Ensuring QuickEats schema + seed is applied..."

    # Migration tracking table (idempotent)
    run_psql "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    # Check if our migration was already applied
    local applied
    applied="$(psql "$(cat db_connection.txt)" -tA -c "SELECT 1 FROM schema_migrations WHERE version='2026-02-16_quickeats_init' LIMIT 1;")"
    if [ "${applied}" = "1" ]; then
        echo "QuickEats schema migration already applied (2026-02-16_quickeats_init). Skipping."
        return 0
    fi

    # --- Types / enums ---
    run_psql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN CREATE TYPE user_role AS ENUM ('customer','courier','restaurant_owner','admin'); END IF; END \$\$;"

    # --- Core tables ---
    run_psql "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, full_name TEXT NOT NULL, phone TEXT, role user_role NOT NULL DEFAULT 'customer', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    run_psql "CREATE TABLE IF NOT EXISTS restaurants (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL, description TEXT, address TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    run_psql "CREATE TABLE IF NOT EXISTS menu_categories (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE, name TEXT NOT NULL, sort_order INT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    run_psql "CREATE TABLE IF NOT EXISTS menu_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE, category_id UUID REFERENCES menu_categories(id) ON DELETE SET NULL, name TEXT NOT NULL, description TEXT, price_cents INT NOT NULL CHECK (price_cents >= 0), available BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    # Cart draft (for building an order before checkout)
    run_psql "CREATE TABLE IF NOT EXISTS cart_drafts (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE(user_id, restaurant_id));"

    run_psql "CREATE TABLE IF NOT EXISTS cart_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), cart_id UUID NOT NULL REFERENCES cart_drafts(id) ON DELETE CASCADE, menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE, quantity INT NOT NULL CHECK (quantity > 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE(cart_id, menu_item_id));"

    # Orders
    run_psql "CREATE TABLE IF NOT EXISTS orders (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT, restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE RESTRICT, status TEXT NOT NULL DEFAULT 'pending', subtotal_cents INT NOT NULL DEFAULT 0 CHECK (subtotal_cents >= 0), delivery_fee_cents INT NOT NULL DEFAULT 0 CHECK (delivery_fee_cents >= 0), total_cents INT NOT NULL DEFAULT 0 CHECK (total_cents >= 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    run_psql "CREATE TABLE IF NOT EXISTS order_items (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE RESTRICT, name_snapshot TEXT NOT NULL, price_cents_snapshot INT NOT NULL CHECK (price_cents_snapshot >= 0), quantity INT NOT NULL CHECK (quantity > 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    # Payments
    run_psql "CREATE TABLE IF NOT EXISTS payments (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE, provider TEXT NOT NULL DEFAULT 'mock', status TEXT NOT NULL DEFAULT 'unpaid', amount_cents INT NOT NULL CHECK (amount_cents >= 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    # Deliveries + tracking events (for realtime tracking)
    run_psql "CREATE TABLE IF NOT EXISTS deliveries (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), order_id UUID NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE, courier_user_id UUID REFERENCES users(id) ON DELETE SET NULL, status TEXT NOT NULL DEFAULT 'created', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    run_psql "CREATE TABLE IF NOT EXISTS delivery_tracking_events (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), delivery_id UUID NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE, event_type TEXT NOT NULL, lat DOUBLE PRECISION, lng DOUBLE PRECISION, note TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"

    # --- Seed data (idempotent via ON CONFLICT) ---
    # Users: customer, courier, restaurant owner
    run_psql "INSERT INTO users (email, password_hash, full_name, role) VALUES ('customer1@quickeats.local','demo_hash','Customer One','customer') ON CONFLICT (email) DO NOTHING;"
    run_psql "INSERT INTO users (email, password_hash, full_name, role) VALUES ('courier1@quickeats.local','demo_hash','Courier One','courier') ON CONFLICT (email) DO NOTHING;"
    run_psql "INSERT INTO users (email, password_hash, full_name, role) VALUES ('owner1@quickeats.local','demo_hash','Owner One','restaurant_owner') ON CONFLICT (email) DO NOTHING;"

    # Restaurant owned by owner1
    run_psql "INSERT INTO restaurants (owner_user_id, name, description, address) SELECT u.id, 'QuickEats Pizza', 'Hand-tossed pizza and sides', '123 Main St' FROM users u WHERE u.email='owner1@quickeats.local' AND NOT EXISTS (SELECT 1 FROM restaurants r WHERE r.name='QuickEats Pizza');"

    # Menu categories
    run_psql "INSERT INTO menu_categories (restaurant_id, name, sort_order) SELECT r.id, 'Pizzas', 1 FROM restaurants r WHERE r.name='QuickEats Pizza' AND NOT EXISTS (SELECT 1 FROM menu_categories c WHERE c.restaurant_id=r.id AND c.name='Pizzas');"
    run_psql "INSERT INTO menu_categories (restaurant_id, name, sort_order) SELECT r.id, 'Sides', 2 FROM restaurants r WHERE r.name='QuickEats Pizza' AND NOT EXISTS (SELECT 1 FROM menu_categories c WHERE c.restaurant_id=r.id AND c.name='Sides');"

    # Menu items
    run_psql "INSERT INTO menu_items (restaurant_id, category_id, name, description, price_cents, available) SELECT r.id, c.id, 'Margherita', 'Tomato, mozzarella, basil', 1299, TRUE FROM restaurants r JOIN menu_categories c ON c.restaurant_id=r.id AND c.name='Pizzas' WHERE r.name='QuickEats Pizza' AND NOT EXISTS (SELECT 1 FROM menu_items mi WHERE mi.restaurant_id=r.id AND mi.name='Margherita');"
    run_psql "INSERT INTO menu_items (restaurant_id, category_id, name, description, price_cents, available) SELECT r.id, c.id, 'Pepperoni', 'Pepperoni and mozzarella', 1499, TRUE FROM restaurants r JOIN menu_categories c ON c.restaurant_id=r.id AND c.name='Pizzas' WHERE r.name='QuickEats Pizza' AND NOT EXISTS (SELECT 1 FROM menu_items mi WHERE mi.restaurant_id=r.id AND mi.name='Pepperoni');"
    run_psql "INSERT INTO menu_items (restaurant_id, category_id, name, description, price_cents, available) SELECT r.id, c.id, 'Garlic Knots', 'Garlic butter knots', 699, TRUE FROM restaurants r JOIN menu_categories c ON c.restaurant_id=r.id AND c.name='Sides' WHERE r.name='QuickEats Pizza' AND NOT EXISTS (SELECT 1 FROM menu_items mi WHERE mi.restaurant_id=r.id AND mi.name='Garlic Knots');"

    # Mark migration applied
    run_psql "INSERT INTO schema_migrations (version) VALUES ('2026-02-16_quickeats_init') ON CONFLICT (version) DO NOTHING;"
    echo "QuickEats schema + seed applied successfully."
}

# -----------------------------
# Start/ensure Postgres running
# -----------------------------

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"

    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi

    # Even if Postgres is already running, ensure schema+seed is present/reproducible.
    if [ -f "db_connection.txt" ]; then
        ensure_quickeats_schema_and_seed
    fi

    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."

    # Try to connect and verify the database exists
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."

        # Ensure db_connection exists then apply schema/seed
        if [ -f "db_connection.txt" ]; then
            ensure_quickeats_schema_and_seed
        fi

        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 5

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

# Apply schema + seed after DB is reachable and connection string is saved
ensure_quickeats_schema_and_seed

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
