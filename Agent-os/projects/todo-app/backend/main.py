from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional

app = FastAPI()

# In-memory storage for todos
todos_db: List[dict] = []
next_id = 1

# Pydantic model for Todo item
class TodoItem(BaseModel):
    id: int
    title: str
    done: bool = False

# Pydantic model for creating a Todo item (id is generated)
class TodoCreate(BaseModel):
    title: str

# Pydantic model for updating a Todo item
class TodoUpdate(BaseModel):
    done: bool

# Configure CORS
origins = [
    "http://localhost:3000",  # Assuming your frontend runs on port 3000
    "http://127.0.0.1:3000",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/todos", response_model=TodoItem, status_code=201)
def create_todo(todo: TodoCreate):
    """
    Creates a new todo item.
    """
    global next_id
    new_todo = {"id": next_id, "title": todo.title, "done": False}
    todos_db.append(new_todo)
    next_id += 1
    return new_todo

@app.get("/todos", response_model=List[TodoItem])
def list_todos():
    """
    Lists all todo items.
    """
    return todos_db

@app.patch("/todos/{id}", response_model=TodoItem)
def update_todo_status(id: int, update_data: TodoUpdate):
    """
    Updates the 'done' status of a specific todo item.
    """
    for todo in todos_db:
        if todo["id"] == id:
            todo["done"] = update_data.done
            return todo
    raise HTTPException(status_code=404, detail="Todo not found")

@app.delete("/todos/{id}", status_code=204)
def delete_todo(id: int):
    """
    Deletes a specific todo item.
    """
    global todos_db
    initial_len = len(todos_db)
    todos_db = [todo for todo in todos_db if todo["id"] != id]
    if len(todos_db) == initial_len:
        raise HTTPException(status_code=404, detail="Todo not found")
    return

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
