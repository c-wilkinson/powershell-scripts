param(
  [string]$ContainerName = "sql2022",
  [string]$SaPassword    = "Pa55word",
  [string]$DbName        = "TestLab",
  [int]$Users            = 10000,
  [int]$Products         = 5000,
  [int]$Orders           = 2000000,
  [switch]$RecreateDb                # drops and recreates the DB
)

function Invoke-OrThrow {
  param([string]$Cmd, [string]$Err = "Command failed")
  $out = Invoke-Expression $Cmd 2>&1
  if ($LASTEXITCODE -ne 0) { throw "$Err`n$out" }
  return $out
}

$existing = (docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $ContainerName })
if (-not $existing) {
  Write-Host "Starting new SQL Server container '$ContainerName'..."
  Invoke-OrThrow "docker run -d --name $ContainerName -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=$SaPassword' -p 1433:1433 mcr.microsoft.com/mssql/server:2022-latest" "Failed to start container"
} elseif (-not (docker ps --format "{{.Names}}" | Where-Object { $_ -eq $ContainerName })) {
  Write-Host "Starting existing container '$ContainerName'..."
  Invoke-OrThrow "docker start $ContainerName" "Failed to start existing container"
}

Write-Host "Waiting for SQL Server to become ready..."
$tries = 60
for ($i=1; $i -le $tries; $i++) {
  $ok = docker exec $ContainerName /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $SaPassword -C -Q "SELECT 1" 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Host "SQL is ready."; break }
  Start-Sleep -Seconds 2
  if ($i -eq $tries) { throw "SQL Server did not become ready in time." }
}

$tmp = New-TemporaryFile
@'
-- ============================================================
-- TestLab: lightweight test DB for T-SQL exercises
-- ============================================================

IF '$(RECREATE)' = '1'
BEGIN
  IF DB_ID('$(DBNAME)') IS NOT NULL
  BEGIN
    ALTER DATABASE [$(DBNAME)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$(DBNAME)];
  END
END

IF DB_ID('$(DBNAME)') IS NULL
BEGIN
  PRINT 'Creating database $(DBNAME)...';
  CREATE DATABASE [$(DBNAME)];
END
GO
USE [$(DBNAME)];
GO

-- TABLES
IF OBJECT_ID('dbo.Users') IS NULL
CREATE TABLE dbo.Users
(
  UserID INT IDENTITY(1,1) PRIMARY KEY,
  Username NVARCHAR(50) NOT NULL,
  Email NVARCHAR(255) NOT NULL UNIQUE,
  CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  IsActive BIT NOT NULL DEFAULT 1
);

IF OBJECT_ID('dbo.Products') IS NULL
CREATE TABLE dbo.Products
(
  ProductID INT IDENTITY(1,1) PRIMARY KEY,
  Name NVARCHAR(100) NOT NULL,
  Category NVARCHAR(50) NOT NULL,
  Price DECIMAL(10,2) NOT NULL,
  CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID('dbo.Orders') IS NULL
CREATE TABLE dbo.Orders
(
  OrderID BIGINT IDENTITY(1,1) PRIMARY KEY,
  UserID INT NOT NULL REFERENCES dbo.Users(UserID),
  OrderDate DATETIME2 NOT NULL,
  Status NVARCHAR(20) NOT NULL
);

IF OBJECT_ID('dbo.OrderItems') IS NULL
CREATE TABLE dbo.OrderItems
(
  OrderItemID BIGINT IDENTITY(1,1) PRIMARY KEY,
  OrderID BIGINT NOT NULL REFERENCES dbo.Orders(OrderID),
  ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
  Quantity INT NOT NULL CHECK (Quantity>=1),
  UnitPrice DECIMAL(10,2) NOT NULL
);

IF OBJECT_ID('dbo.Posts') IS NULL
CREATE TABLE dbo.Posts
(
  PostID BIGINT IDENTITY(1,1) PRIMARY KEY,
  UserID INT NOT NULL REFERENCES dbo.Users(UserID),
  Title NVARCHAR(200) NOT NULL,
  Body NVARCHAR(MAX) NOT NULL,
  CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID('dbo.Events') IS NULL
CREATE TABLE dbo.Events
(
  EventID BIGINT IDENTITY(1,1) PRIMARY KEY,
  OccurredAt DATETIME2 NOT NULL,
  EventType NVARCHAR(50) NOT NULL,
  Payload NVARCHAR(4000) NULL
);

-- INDEXES
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Users_CreatedAt' AND object_id=OBJECT_ID('dbo.Users'))
  CREATE INDEX IX_Users_CreatedAt ON dbo.Users(CreatedAt);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Products_Category' AND object_id=OBJECT_ID('dbo.Products'))
  CREATE INDEX IX_Products_Category ON dbo.Products(Category);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Orders_OrderDate' AND object_id=OBJECT_ID('dbo.Orders'))
  CREATE INDEX IX_Orders_OrderDate ON dbo.Orders(OrderDate);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_OrderItems_OrderID' AND object_id=OBJECT_ID('dbo.OrderItems'))
  CREATE INDEX IX_OrderItems_OrderID ON dbo.OrderItems(OrderID);

-- VIEWS
IF OBJECT_ID('dbo.v_OrderSummary') IS NULL
EXEC('CREATE VIEW dbo.v_OrderSummary AS
  SELECT o.OrderID,o.UserID,o.OrderDate,
         COUNT(oi.OrderItemID) AS ItemCount,
         SUM(oi.Quantity*oi.UnitPrice) AS OrderTotal
  FROM dbo.Orders o
  JOIN dbo.OrderItems oi ON oi.OrderID=o.OrderID
  GROUP BY o.OrderID,o.UserID,o.OrderDate;');

-- FUNCTIONS
IF OBJECT_ID('dbo.udf_SalesTax') IS NULL
EXEC('CREATE FUNCTION dbo.udf_SalesTax(@amount DECIMAL(10,2),@rate DECIMAL(5,2))
RETURNS DECIMAL(12,2)
AS BEGIN RETURN ROUND(@amount*(@rate/100.0),2); END');

IF OBJECT_ID('dbo.itvf_OrdersByUser') IS NULL
EXEC('CREATE FUNCTION dbo.itvf_OrdersByUser(@UserID INT)
RETURNS TABLE AS RETURN
 SELECT o.OrderID,o.UserID,o.OrderDate,SUM(oi.Quantity*oi.UnitPrice) AS OrderTotal
 FROM dbo.Orders o JOIN dbo.OrderItems oi ON oi.OrderID=o.OrderID
 WHERE o.UserID=@UserID GROUP BY o.OrderID,o.UserID,o.OrderDate;');

-- STORED PROCEDURES
IF OBJECT_ID('dbo.usp_GetTopCustomers') IS NULL
EXEC('CREATE PROCEDURE dbo.usp_GetTopCustomers
  @From DATETIME2,@To DATETIME2,@TopN INT=10
AS BEGIN
 SET NOCOUNT ON;
 SELECT TOP(@TopN) u.UserID,u.Username,SUM(oi.Quantity*oi.UnitPrice) AS Spend
 FROM dbo.Users u
 JOIN dbo.Orders o ON o.UserID=u.UserID AND o.OrderDate>=@From AND o.OrderDate<@To
 JOIN dbo.OrderItems oi ON oi.OrderID=o.OrderID
 GROUP BY u.UserID,u.Username
 ORDER BY Spend DESC;
END');

PRINT 'Test data ready.';
GO
'@ | Set-Content -Encoding UTF8 $tmp.FullName

Write-Host "Copying init script into container..."
Invoke-OrThrow "docker cp $($tmp.FullName) `"$ContainerName`:/tmp/init.sql`"" "Failed to copy init script into container"

Write-Host "Executing init script inside container..."
$recreateFlag = if ($RecreateDb) { 1 } else { 0 }
Invoke-OrThrow ("docker exec {0} /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P {1} -C -b -i /tmp/init.sql -v DBNAME=""{2}"" RECREATE={3} USERS={4} PRODUCTS={5} ORDERS={6}" -f `
  $ContainerName, $SaPassword, $DbName, $recreateFlag, $Users, $Products, $Orders) "Failed to execute init script"

Write-Host ""
Write-Host "Database '$DbName' created and seeded successfully."
Write-Host "Try:"
Write-Host "  docker exec -it $ContainerName /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $SaPassword -C -Q `"SELECT TOP 5 * FROM [$DbName].dbo.v_OrderSummary ORDER BY OrderTotal DESC;`""
Write-Host ""
Write-Host "Connect from host:"
Write-Host "  Server=localhost,1433; User ID=sa; Password=$SaPassword;"
Write-Host ""
Write-Host "To recreate:"
Write-Host "  .\\create-test-db.ps1 -SaPassword '$SaPassword' -DbName '$DbName' -RecreateDb"
